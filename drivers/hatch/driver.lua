-- Hatch account coordinator.
--
-- Owns the single cloud connection for the whole Hatch account (auth -> AWS IoT
-- MQTT -> device shadows; see src/hatch/*), discovers devices, and exposes a
-- dynamic binding per device-function that the companion drivers bind to:
--   HATCH_MEDIA  -> hatch_media  (sound machine)
--   HATCH_LIGHT  -> hatch_light  (night light)
--   HATCH_VOLUME -> hatch_volume (volume as a dimmer)
-- Companions send ENTITY_COMMAND over the binding; the coordinator maps it to a
-- shadow update. Shadow state is pushed back to companions as UPDATE_STATE.

--#ifdef DRIVERCENTRAL
DC_PID = 0 -- TODO: Assign DriverCentral product ID
DC_X = nil
DC_FILENAME = "hatch.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-hatch"
DRIVER_FILENAMES = {
  "hatch.c4z",
  "hatch_media.c4z",
  "hatch_light.c4z",
  "hatch_volume.c4z",
}
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

JSON = require("JSON")

local log = require("lib.logging")
local bindings = require("lib.bindings")
local Api = require("hatch.api")
local Connection = require("hatch.connection")
local Device = require("hatch.device")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

--- Binding namespaces / companion connection classes.
local NS_MEDIA = "HATCH_MEDIA"
local NS_LIGHT = "HATCH_LIGHT"
local NS_VOLUME = "HATCH_VOLUME"

gInitialized = false

local connection = nil
local api = nil
--- thing -> device record { name, product, thingName, macAddress }.
local devicesByThing = {}
--- thing -> parsed Device state.
local stateByThing = {}
--- thing -> { sounds, soundsById, favorites }.
local catalogByThing = {}
--- thing -> last non-black { red, green, blue } the device showed. An off light
--- reports black, so live state alone can't answer "what colour was this?".
local lastColorByThing = {}
--- thing -> last seen shadow dataVersion. See noteDataVersion().
local dataVersionByThing = {}
local CATALOG_REFRESH_DELAY = 5 * ONE_SECOND

--- Sound machine exists on every Hatch; the night light on all but Rest Mini.
local function hasLight(product)
  return product ~= "restMini"
end

--- Content API product family for a device (riot family shares the "riot" catalog).
local function catalogProduct(product)
  if product == "riot" or product == "riotPlus" then
    return "riot"
  end
  return product
end

--------------------------------------------------------------------------------
-- Shadow control
--------------------------------------------------------------------------------

local function control(thing, desired)
  if connection and desired then
    connection:updateShadow(thing, desired)
  end
end

--------------------------------------------------------------------------------
-- State push to companions
--------------------------------------------------------------------------------

--- Contentful serves full-size landscape art; resize on their CDN so neither the
--- controller nor Navigator fetches a 1600px asset for a small square.
local function soundArtUrl(url)
  if not url or url == "" or url:find("?", 1, true) then
    return url ~= "" and url or nil
  end
  return url .. "?w=512&h=512&fit=fill&fm=jpg&q=80"
end

--- Best human title for what's currently playing. A favorite/routine (srId is
--- the favorite id) shows the favorite's name; a raw sound shows the catalog
--- title, falling back to a favorite step that references the same sound id.
--- Favorites often play sounds that aren't in the browsable catalog (e.g. Brown
--- Noise), so a plain soundId->catalog lookup misses and reads "Sound <id>".
local function resolveNowTitle(state, catalog)
  local favorites = catalog.favorites or {}
  if state.playing == "routine" and state.srId and state.srId ~= 0 then
    for _, fav in ipairs(favorites) do
      if tonumber(fav.id) == state.srId then
        return fav.name
      end
    end
  end
  local soundsById = catalog.soundsById or {}
  local sound = state.soundId and soundsById[tostring(state.soundId)]
  if sound and sound.title then
    return sound.title
  end
  if state.soundId then
    for _, fav in ipairs(favorites) do
      for _, step in ipairs(fav.steps or {}) do
        if step.sound and tonumber(step.sound.id) == state.soundId then
          return step.name or fav.name
        end
      end
    end
  end
  return nil
end

--- Cover art for what's playing. soundId is the sound a routine is currently on,
--- so a favorite resolves to its step's artwork for free.
local function resolveNowImage(state, catalog)
  if not state.soundId then
    return nil
  end
  local key = tostring(state.soundId)
  local sound = (catalog.soundsById or {})[key]
  if sound and sound.image then
    return sound.image
  end
  -- Falls through for a favorite playing a sound outside the browse catalog.
  return soundArtUrl((catalog.artById or {})[key])
end

local function pushMediaState(thing)
  local binding = bindings:getDynamicBinding(NS_MEDIA, thing)
  if not binding then
    return
  end
  local state = stateByThing[thing] or {}
  local catalog = catalogByThing[thing] or {}
  SendToProxy(binding.bindingId, "UPDATE_STATE", {
    state = SerializeSafe({
      online = state.online,
      isPlaying = state.isPlaying,
      soundId = state.soundId,
      soundTitle = state.isPlaying and resolveNowTitle(state, catalog) or nil,
      soundImage = state.isPlaying and resolveNowImage(state, catalog) or nil,
      volumePct = state.volumePct,
      -- srId is only meaningful while a routine runs; the device keeps its last
      -- one when idle or playing a plain sound.
      favoriteId = state.playing == "routine" and state.srId or nil,
    }),
    sounds = SerializeSafe(catalog.sounds or {}),
    favorites = SerializeSafe(catalog.favorites or {}),
    -- soundId -> artwork, so the companion can give a favorite the art of the
    -- sound its routine plays even when that sound isn't in the browse list.
    artwork = SerializeSafe(catalog.artById or {}),
  }, "NOTIFY")
end

local function pushLightState(thing)
  local binding = bindings:getDynamicBinding(NS_LIGHT, thing)
  if not binding then
    return
  end
  local state = stateByThing[thing] or {}
  SendToProxy(binding.bindingId, "UPDATE_STATE", {
    state = SerializeSafe({
      online = state.online,
      on = state.lightOn,
      red = state.red,
      green = state.green,
      blue = state.blue,
      brightnessPct = state.brightnessPct,
    }),
  }, "NOTIFY")
end

--- Volume presented as a dimmer: brightness IS the volume percentage, and the
--- light being on means the sound machine is playing. Its own binding so the
--- sync lives in the driver, which can decline to send an echo; Programming has
--- no way to express "this change came from the other side".
local function pushVolumeState(thing)
  local binding = bindings:getDynamicBinding(NS_VOLUME, thing)
  if not binding then
    return
  end
  local state = stateByThing[thing] or {}
  local catalog = catalogByThing[thing] or {}
  local params = {
    state = SerializeSafe({
      online = state.online,
      on = state.isPlaying,
      brightnessPct = state.volumePct,
    }),
  }
  -- The companion needs the catalog to build its "what does on play" list, but
  -- only once BOTH fetches have returned. They resolve independently and each
  -- pushes, so sending a half-filled catalog would have the companion rebuild
  -- its list with no favorites in it and drop the installer's saved choice.
  -- Absent is not the same as empty here, which is why these are omitted rather
  -- than defaulted to {}.
  if catalog.sounds and catalog.favorites then
    params.sounds = SerializeSafe(catalog.sounds)
    params.favorites = SerializeSafe(catalog.favorites)
  end
  SendToProxy(binding.bindingId, "UPDATE_STATE", params, "NOTIFY")
end

--- Tell every bound companion the cloud connection dropped, so they report it
--- instead of showing stale state as though it were live.
local function pushDisconnect()
  for _, ns in ipairs({ NS_MEDIA, NS_LIGHT, NS_VOLUME }) do
    for _, binding in pairs(bindings:getDynamicBindings(ns)) do
      if binding.bindingId then
        SendToProxy(binding.bindingId, "UPDATE_DISCONNECT", {}, "NOTIFY")
      end
    end
  end
end

--- Re-push state on reconnect so companions leave the disconnected state
--- without waiting for the next shadow update.
local function pushAllState()
  for thing, _ in pairs(devicesByThing) do
    pushMediaState(thing)
    pushLightState(thing)
    pushVolumeState(thing)
  end
end

--------------------------------------------------------------------------------
-- ENTITY_COMMAND handling (companion -> coordinator -> shadow)
--------------------------------------------------------------------------------

local function handleMediaCommand(thing, body)
  local catalog = catalogByThing[thing] or {}
  local soundsById = catalog.soundsById or {}
  local command = body.command
  if command == "play" then
    local sound = soundsById[tostring(body.soundId)]
    if sound then
      control(thing, Device.playSound(sound))
    end
  elseif command == "favorite" then
    control(thing, Device.playFavorite(body.favoriteId))
  elseif command == "stop" then
    control(thing, Device.stop())
  elseif command == "volume" then
    control(thing, Device.setVolume(tonumber(body.level)))
  end
end

--- The volume a favorite will apply, read from the routine rather than imposed.
--- Lives in `steps[].sound.v` as a raw 0..65535 value; the sibling
--- `steps[].color.i` is the light's brightness, not volume. First enabled step
--- wins, since that is where a routine starts.
local function favoriteVolumePct(fav)
  if type(fav) ~= "table" then
    return nil
  end
  for _, step in ipairs(fav.steps or {}) do
    if type(step) == "table" and step.enabled ~= false and type(step.sound) == "table" then
      local raw = tonumber(step.sound.v)
      if raw and raw > 0 then
        return Device.pctFromRaw(raw)
      end
    end
  end
  return nil
end

--- Volume-as-a-dimmer commands. Brightness maps straight to volume, on/off to
--- play and stop. Setting brightness never starts playback: the Hatch accepts a
--- volume change while stopped, so the level can be staged beforehand.
local function handleVolumeCommand(thing, body)
  local state = stateByThing[thing] or {}
  local catalog = catalogByThing[thing] or {}
  local command = body.command
  if command == "on" then
    -- The installer picks what "on" plays: the device's last sound is often
    -- absent from the browsable catalog, so resuming it can do nothing at all.
    if body.favoriteId then
      -- A favorite applies its own volume, so the preset is deliberately ignored.
      control(thing, Device.playFavorite(body.favoriteId))
      -- Show the favorite's level now rather than waiting for the device to
      -- echo it, so the slider does not sit at the old value. The next shadow
      -- update confirms it.
      local fav
      for _, candidate in ipairs(catalog.favorites or {}) do
        if tostring(candidate.id) == tostring(body.favoriteId) then
          fav = candidate
          break
        end
      end
      local pct = favoriteVolumePct(fav)
      log:debug("Favorite %s volume resolved to %s", tostring(body.favoriteId), tostring(pct))
      if pct then
        stateByThing[thing] = stateByThing[thing] or {}
        stateByThing[thing].volumePct = pct
        -- The companion reports 0 while not playing, so an optimistic level
        -- without this reads as off until the shadow lands.
        stateByThing[thing].isPlaying = true
        pushVolumeState(thing)
      end
    else
      -- A sound carries no volume, so the level goes out with it. See
      -- Device.playSound().
      local level = tonumber(body.brightness)
      local soundId = body.soundId or state.soundId
      local sound = soundId and (catalog.soundsById or {})[tostring(soundId)]
      if sound then
        control(thing, Device.playSound(sound, level and level > 0 and level or nil))
      elseif level and level > 0 then
        control(thing, Device.setVolume(level))
      end
    end
  elseif command == "off" then
    -- Stop only: leaving the volume alone means the next start is not silent.
    control(thing, Device.stop())
  elseif command == "setBrightness" then
    local level = tonumber(body.brightness) or 0
    control(thing, Device.setVolume(level))
  end
end

-- Brightness to use when turning on or setting a color. An explicit request
-- wins; otherwise keep the current level. Never resolve to 0: the device treats
-- a color at intensity 0 as on-but-dark, so a bare "on" (or a color pick from a
-- fully-off state, where brightnessPct is 0) falls back to full brightness.
local function onBrightness(body, state)
  local bri = tonumber(body.brightness) or state.brightnessPct
  if not bri or bri <= 0 then
    return 100
  end
  return bri
end

local function handleLightCommand(thing, body)
  local state = stateByThing[thing] or {}
  local command = body.command
  local red = tonumber(body.red) or state.red or 255
  local green = tonumber(body.green) or state.green or 255
  local blue = tonumber(body.blue) or state.blue or 255
  -- An off light reports black; restore the last real colour instead, falling
  -- back to white since the device refuses to illuminate on black.
  if red == 0 and green == 0 and blue == 0 then
    local last = lastColorByThing[thing] or {}
    red = last.red or 255
    green = last.green or 255
    blue = last.blue or 255
  end
  if command == "on" then
    control(thing, Device.setColor(red, green, blue, onBrightness(body, state), state.playing))
  elseif command == "off" then
    control(thing, Device.lightOff(state.playing))
  elseif command == "setColor" then
    control(thing, Device.setColor(red, green, blue, onBrightness(body, state), state.playing))
  elseif command == "setBrightness" then
    local brightness = tonumber(body.brightness) or 0
    if brightness <= 0 then
      control(thing, Device.lightOff(state.playing))
    else
      control(thing, Device.setColor(red, green, blue, brightness, state.playing))
    end
  end
end

--------------------------------------------------------------------------------
-- Dynamic bindings (one per device-function)
--------------------------------------------------------------------------------

local function setupDeviceBindings(device)
  local thing = device.thingName

  local mediaBinding =
    bindings:getOrAddDynamicBinding(NS_MEDIA, thing, "PROXY", true, device.name .. " Sound Machine", NS_MEDIA)
  if mediaBinding then
    RFP[mediaBinding.bindingId] = function(_idBinding, strCommand, tParams, _args)
      if strCommand == "REFRESH_STATE" then
        pushMediaState(thing)
      elseif strCommand == "ENTITY_COMMAND" then
        handleMediaCommand(thing, DeserializeSafe(Select(tParams, "body")) or {})
      end
    end
    OBC[mediaBinding.bindingId] = function()
      pushMediaState(thing)
    end
  end

  local volumeBinding =
    bindings:getOrAddDynamicBinding(NS_VOLUME, thing, "PROXY", true, device.name .. " Volume", NS_VOLUME)
  if volumeBinding then
    RFP[volumeBinding.bindingId] = function(_idBinding, strCommand, tParams, _args)
      if strCommand == "REFRESH_STATE" then
        pushVolumeState(thing)
      elseif strCommand == "ENTITY_COMMAND" then
        handleVolumeCommand(thing, DeserializeSafe(Select(tParams, "body")) or {})
      end
    end
    OBC[volumeBinding.bindingId] = function()
      pushVolumeState(thing)
    end
  end

  if hasLight(device.product) then
    local lightBinding =
      bindings:getOrAddDynamicBinding(NS_LIGHT, thing, "PROXY", true, device.name .. " Night Light", NS_LIGHT)
    if lightBinding then
      RFP[lightBinding.bindingId] = function(_idBinding, strCommand, tParams, _args)
        if strCommand == "REFRESH_STATE" then
          pushLightState(thing)
        elseif strCommand == "ENTITY_COMMAND" then
          handleLightCommand(thing, DeserializeSafe(Select(tParams, "body")) or {})
        end
      end
      OBC[lightBinding.bindingId] = function()
        pushLightState(thing)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Catalog
--------------------------------------------------------------------------------

local function loadCatalog(device)
  local thing = device.thingName
  catalogByThing[thing] = catalogByThing[thing] or {}

  -- Restore devices get their catalog from Contentful GraphQL; everyone else
  -- from the REST content endpoint (the riot family shares the "riot" catalog).
  local product = device.product
  local soundsRequest
  -- Contentful carries artwork for every family, including the ones whose
  -- catalog we load over REST, so it is always the artwork source.
  local artworkProduct
  if product == "restoreV4" or product == "restoreV5" then
    soundsRequest = api:fetchRestoreSounds(product)
    artworkProduct = product
  else
    artworkProduct = catalogProduct(product)
    soundsRequest = api:fetchSounds(artworkProduct)
  end

  soundsRequest:next(function(items)
    local sounds, soundsById = {}, {}
    for _, s in ipairs(items or {}) do
      local id = s.id or s.hatchId
      local url = s.wavUrl or s.url or (s.wavFile and s.wavFile.url) or s.mp3Url
      local title = s.title or s.name
      if id and url and title and id ~= Device.NO_SOUND_ID then
        local sound = {
          id = id,
          url = url,
          title = title,
          -- Contentful catalogs carry this; REST ones get it from the lookup below.
          image = soundArtUrl(s.image and s.image.url),
        }
        sounds[#sounds + 1] = sound
        soundsById[tostring(id)] = sound
      end
    end
    catalogByThing[thing].sounds = sounds
    catalogByThing[thing].soundsById = soundsById
    log:info("Hatch: %s loaded %d sounds", device.name, #sounds)
    pushMediaState(thing)
    pushVolumeState(thing)

    -- Fetched only once the catalog is usable, so a slow or failed artwork
    -- lookup can never hold up browsing or playback.
    api:fetchSoundArtwork(artworkProduct):next(function(rawArt)
      local artById = {}
      for id, url in pairs(rawArt or {}) do
        artById[id] = soundArtUrl(url)
      end
      -- Kept whole, not just merged: favorites routinely play sounds the browse
      -- catalog doesn't list (Brown Noise), and those still have artwork here.
      catalogByThing[thing].artById = artById
      local matched = 0
      for _, sound in ipairs(sounds) do
        if not sound.image then
          local art = artById[tostring(sound.id)]
          if art then
            sound.image = art
            matched = matched + 1
          end
        end
      end
      if matched > 0 then
        log:info("Hatch: %s matched artwork for %d sound(s)", device.name, matched)
        pushMediaState(thing)
      end
    end)
  end, function(err)
    log:warn("Hatch: %s sound fetch failed: %s", device.name, tostring(type(err) == "table" and err.error or err))
  end)

  api:fetchRoutines(device.macAddress):next(function(items)
    catalogByThing[thing].favorites = items or {}
    log:info("Hatch: %s loaded %d favorites", device.name, #(items or {}))
    pushMediaState(thing)
    pushVolumeState(thing)
  end, function(err)
    -- Without this the rejection goes nowhere: the companions are held back
    -- until both fetches return, so a failure here reads as "this account has
    -- no favorites" with nothing in the log to say otherwise.
    log:warn("Hatch: %s favorite fetch failed: %s", device.name, tostring(type(err) == "table" and err.error or err))
  end)
end

--- Reload a device's catalog when the account content behind it changes.
---
--- The shadow's dataVersion moves when sounds or favorites change and is
--- otherwise static for weeks, so it signals a refetch without polling. One
--- edit bumps it several times as the data syncs; re-arming the timer resets
--- it, so the reload runs once after the bumps stop.
local function noteDataVersion(thing, dataVersion)
  if type(dataVersion) ~= "string" or dataVersion == "" then
    return
  end
  local previous = dataVersionByThing[thing]
  dataVersionByThing[thing] = dataVersion
  if previous == nil or previous == dataVersion then
    return
  end
  log:info("Hatch: %s content changed (%s -> %s); reloading catalog", thing, previous, dataVersion)
  SetTimer("CatalogRefresh:" .. thing, CATALOG_REFRESH_DELAY, function()
    local device = devicesByThing[thing]
    if device then
      loadCatalog(device)
    end
  end)
end

--------------------------------------------------------------------------------
-- Connection
--------------------------------------------------------------------------------

local function setConnectionStatus(text)
  UpdateProperty("Connection Status", text)
end

local function startConnection()
  if connection then
    connection:stop()
    connection = nil
  end
  local email = Properties["Email"]
  local password = Properties["Password"]
  if IsEmpty(email) or IsEmpty(password) then
    setConnectionStatus("Enter account email and password")
    return
  end

  setConnectionStatus("Connecting...")
  api = Api:new({ email = email, password = password })

  -- MQTT client id must be unique per controller. Two controllers (or a lingering
  -- stale connection) sharing an id make AWS IoT kick one whenever the other
  -- connects, which flaps the link and drops commands. The controller MAC keeps it
  -- unique across controllers; the device id disambiguates instances within one.
  local clientId = string.format(
    "control4-hatch-%s-%s",
    (tostring(C4:GetUniqueMAC() or ""):gsub("[^%w]", "")),
    tostring(C4:GetDeviceID())
  )

  connection = Connection:new({
    api = api,
    clientId = clientId,
    onConnected = function(devices)
      devices = devices or {}
      devicesByThing = {}
      -- Connecting reloads every catalog below, so the next shadow is a first
      -- sighting rather than a change.
      dataVersionByThing = {}
      local names = {}
      for _, device in ipairs(devices) do
        if device.thingName then
          devicesByThing[device.thingName] = device
          setupDeviceBindings(device)
          loadCatalog(device)
          names[#names + 1] = string.format("%s (%s)", device.name, device.product)
        end
      end
      setConnectionStatus(string.format("Connected (%d device%s)", #devices, #devices == 1 and "" or "s"))
      UpdateProperty("Devices", table.concat(names, ", "))
      -- Clear any lingering "Coordinator offline" on the companions. Shadow state
      -- may be a moment behind, but a reconnect should not leave them stuck.
      pushAllState()
      log:info("Hatch connected; %d device(s)", #devices)
    end,
    onShadow = function(thing, reported, _desired)
      if not reported then
        return
      end
      noteDataVersion(thing, reported.dataVersion)
      local parsed = Device.parseState(reported)
      stateByThing[thing] = parsed
      if parsed and not (parsed.red == 0 and parsed.green == 0 and parsed.blue == 0) then
        lastColorByThing[thing] = { red = parsed.red, green = parsed.green, blue = parsed.blue }
      end
      pushMediaState(thing)
      pushLightState(thing)
      pushVolumeState(thing)
    end,
    onDisconnected = function()
      setConnectionStatus("Disconnected (retrying)")
      pushDisconnect()
    end,
  })
  connection:start()
end

--------------------------------------------------------------------------------
-- Multi-instance update coordination (OSS auto-update)
--------------------------------------------------------------------------------

--#ifndef DRIVERCENTRAL
-- Device ids of every Hatch coordinator instance (one per Hatch account),
-- lowest first. Used to elect a single "leader" for update checks and to fan
-- property changes out to peers.
local function getHatchDriverIds()
  local drivers = C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}
  local ids = {}
  for id, _ in pairs(drivers) do
    ids[#ids + 1] = tointeger(id)
  end
  table.sort(ids)
  return ids
end

-- Push a property value to the other coordinator instances so the suite's update
-- settings (Update Channel / Automatic Updates) stay in lockstep across multiple
-- Hatch accounts. SetDeviceProperties only writes when the value differs, so this
-- can't loop.
local function syncPropertyToOtherInstances(propertyName, propertyValue)
  local myId = C4:GetDeviceID()
  for _, deviceId in ipairs(getHatchDriverIds()) do
    if deviceId ~= myId then
      log:info("Syncing '%s' = '%s' to device %d", propertyName, propertyValue, deviceId)
      SetDeviceProperties(deviceId, { [propertyName] = propertyValue }, true)
    end
  end
end

-- Update the whole suite (coordinator + companions) from GitHub. The account
-- driver owns the update for the suite; DRIVER_FILENAMES lists every c4z.
-- @param forceUpdate? boolean Force the update even if the driver is up to date.
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if not IsEmpty(updatedDrivers) then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      else
        log:info("No driver updates available")
      end
    end, function(err)
      log:error("An error occurred updating drivers: %s", err)
    end)
end
--#endif

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  -- Clear stale WebSocket binding addresses left over from previous driver runs.
  -- WebSocket:delete() frees its 6100-6199 binding on a 3-second timer, but
  -- OnDriverDestroyed runs KillAllTimers() which cancels that timer, so an
  -- address can leak across an update/reload. Clear the address only (do NOT
  -- NetDisconnect): NetDisconnect fires each stale binding's OFFLINE handler,
  -- which drives its orphaned socket object into a reconnect and re-grabs a
  -- binding. (Same fix as home_connect.)
  for i = 6100, 6199 do
    pcall(C4.SetBindingAddress, C4, i, "")
  end
  log:trace("OnDriverInit()")

  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  -- Unlock the File* APIs (the OSS GitHub updater downloads through them).
  C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  for p, _ in pairs(Properties) do
    local ok, err = pcall(OnPropertyChanged, p)
    if not ok then
      log:error("OnPropertyChanged('%s') failed: %s", p, tostring(err))
    end
  end

  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    -- Only the leader (lowest device id among the coordinator instances) checks
    -- for updates, so multiple Hatch accounts don't each update the shared c4z.
    local isLeader = Select(getHatchDriverIds(), 1) == C4:GetDeviceID()
    if isLeader and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      UpdateDrivers()
    end
  end, true)
  --#endif

  gInitialized = true
  UpdateProperty("Driver Status", "Ready")
  startConnection()
end

function OnDriverDestroyed()
  if connection then
    connection:stop()
    connection = nil
  end
end

--------------------------------------------------------------------------------
-- Property handlers (OPC)
--------------------------------------------------------------------------------

function OPC.Driver_Status(_v)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

function OPC.Driver_Version(_v)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(v)
  log:setLogMode(v)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    return
  end
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.Log_Level(v)
  log:setLogLevel(v)
  local ultra = log:getLogLevel() >= 6 and log:isPrintEnabled()
  DEBUGPRINT, DEBUG_TIMER, DEBUG_RFN, DEBUG_URL, DEBUG_WEBSOCKET = ultra, ultra, ultra, ultra, ultra
end

function OPC.Email(_v)
  if gInitialized then
    startConnection()
  end
end

function OPC.Password(_v)
  if gInitialized then
    startConnection()
  end
end

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  --#ifndef DRIVERCENTRAL
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Automatic Updates", propertyValue)
  --#endif
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Update Channel", propertyValue)
end
--#endif

--------------------------------------------------------------------------------
-- Command handlers (EC)
--------------------------------------------------------------------------------

function EC.Reconnect(_params)
  log:info("Reconnect requested")
  startConnection()
end

function EC.Reset_Driver(params)
  if params and params["Are You Sure?"] == "Yes" then
    if connection then
      connection:stop()
      connection = nil
    end
    bindings:deleteAllBindings(NS_MEDIA)
    bindings:deleteAllBindings(NS_LIGHT)
    bindings:deleteAllBindings(NS_VOLUME)
    startConnection()
  end
end

--#ifndef DRIVERCENTRAL
function EC.Update_Drivers(_params)
  log:trace("EC.Update_Drivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end
--#endif

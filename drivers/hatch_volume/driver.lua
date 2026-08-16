-- Hatch Volume companion.
--
-- Presents one Hatch device's sound machine volume as a Control4 light_v2
-- dimmer: brightness IS the volume percentage, and the load being on means the
-- sound machine is playing.
--
-- Redundant in native Control4, where the media proxy already carries volume.
-- It exists for integrations that only speak lights: Apple Home has no concept
-- of a media service, so a dimmer is the only way to expose Hatch volume there.
--
-- Owns no cloud connection: it binds to the Hatch account coordinator
-- (HATCH_VOLUME), receives volume/playing as UPDATE_STATE, and sends actions
-- back as ENTITY_COMMAND. Keeping both directions in the driver is the point:
-- the coordinator knows which side a change came from and declines to echo its
-- own writes, which Programming has no way to express.

--#ifdef DRIVERCENTRAL
DC_PID = 0 -- TODO: Assign DriverCentral product ID
DC_X = nil
DC_FILENAME = "hatch_volume.c4z"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local constants = require("constants")
local Favorites = require("hatch.favorites")

local PROXY_BINDING = 5001
local COORD_BINDING = 5002

--- Prefixes distinguishing the two kinds of entry in the "Turn On Plays" list,
--- since a sound and a favorite can share a name.
local SOUND_PREFIX = "Sound: "
local FAVORITE_PREFIX = "Favorite: "

--- Catalog pushed by the coordinator, used to build the list and resolve the
--- installer's choice back to an id.
local sounds = {}
local favorites = {}

gInitialized = false

--- Last state pushed by the coordinator, so TOGGLE and ON can reason about
--- whether anything is playing and what level to restore.
local volumeState = {
  -- Pessimistic until the coordinator hands the device over: reporting a load
  -- as reachable before then makes Navigator accept commands that go nowhere.
  online = false,
  on = false,
  brightnessPct = 0,
}

--------------------------------------------------------------------------------
-- Coordinator link
--------------------------------------------------------------------------------

local function entityCommand(body)
  SendToProxy(COORD_BINDING, "ENTITY_COMMAND", { body = SerializeSafe(body) }, "NOTIFY")
end

--------------------------------------------------------------------------------
-- light_v2 feedback
--------------------------------------------------------------------------------

local function notifyBrightness(pct)
  SendToProxy(PROXY_BINDING, "LIGHT_BRIGHTNESS_CHANGED", {
    LIGHT_BRIGHTNESS_CURRENT = tonumber(pct) or 0,
  }, "NOTIFY")
end

--- Tell the proxy the load is reachable. Without it Navigator greys the dimmer
--- out however correct its brightness reports are.
local function notifyOnline(online)
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = online and true or false }, "NOTIFY")
end

--------------------------------------------------------------------------------
-- State from coordinator
--------------------------------------------------------------------------------

--- Options last written, so an unchanged catalog does not rewrite the list.
local lastPlayOptions = nil

--- Rebuild the "Turn On Plays" options from the catalog, favorites first.
---
--- C4:UpdatePropertyList resets the property to the default it is given, so this
--- rewrites only on a real change and passes the current selection as that
--- default. Otherwise every volume report would clear the installer's choice.
local function updatePlayList()
  local options = {}
  for _, label in ipairs(Favorites.labels(favorites)) do
    options[#options + 1] = Favorites.listSafe(FAVORITE_PREFIX .. label)
  end
  for _, sound in ipairs(sounds) do
    if sound.title then
      options[#options + 1] = Favorites.listSafe(SOUND_PREFIX .. sound.title)
    end
  end
  table.insert(options, 1, constants.SELECT_OPTION)
  local itemStr = table.concat(options, ",")
  if itemStr == lastPlayOptions then
    return
  end
  lastPlayOptions = itemStr

  -- Keep the current choice if it survived, else fall back to the first
  -- favorite: it is self-contained, and (Select) leaves the button doing nothing.
  --
  -- (Select) is deliberately not treated as surviving. It is in every rebuild,
  -- so counting it would pin the property there for good once anything had put
  -- it in that state, rather than recovering on the next rebuild.
  local current = Properties["Turn On Plays"]
  local keep = nil
  if current ~= constants.SELECT_OPTION then
    for _, option in ipairs(options) do
      if option == current then
        keep = current
        break
      end
    end
  end
  if not keep then
    for _, option in ipairs(options) do
      if option:sub(1, #FAVORITE_PREFIX) == FAVORITE_PREFIX then
        keep = option
        break
      end
    end
  end
  keep = keep or constants.SELECT_OPTION
  C4:UpdatePropertyList("Turn On Plays", itemStr, keep)
end

--- The light proxy's Default On (preset) level, used as the starting volume for
--- a plain sound. Favorites carry their own volume and ignore this.
local function presetLevel()
  local proxyId = tonumber(C4:GetProxyDevices())
  local level = proxyId and tonumber(C4:GetDeviceVariable(proxyId, 1006))
  if level and level > 0 then
    return level
  end
  return nil
end

--- Resolve the installer's choice to something the coordinator can play.
--- @return table|nil body extra ENTITY_COMMAND fields, or nil to resume the last sound
local function turnOnTarget()
  local choice = Properties["Turn On Plays"]
  if not choice or choice == "" or choice == constants.SELECT_OPTION then
    -- Nothing chosen yet. Falls through to resuming the last sound only when
    -- the account has no favorites at all.
    local first = favorites[1]
    if first and first.id then
      return { favoriteId = first.id }
    end
    return nil
  end
  local favLabel = choice:match("^" .. FAVORITE_PREFIX .. "(.+)$")
  if favLabel then
    for index, label in ipairs(Favorites.labels(favorites)) do
      if Favorites.listSafe(label) == favLabel then
        return { favoriteId = favorites[index].id }
      end
    end
    return nil
  end
  local title = choice:match("^" .. SOUND_PREFIX .. "(.+)$")
  if title then
    for _, sound in ipairs(sounds) do
      if sound.title and Favorites.listSafe(sound.title) == title then
        return { soundId = sound.id }
      end
    end
  end
  return nil
end

local function applyState(tParams)
  local newSounds = DeserializeSafe(Select(tParams, "sounds"))
  local newFavorites = DeserializeSafe(Select(tParams, "favorites"))
  local catalogChanged = false
  if type(newSounds) == "table" then
    sounds = newSounds
    catalogChanged = true
  end
  if type(newFavorites) == "table" then
    favorites = newFavorites
    catalogChanged = true
  end
  if catalogChanged then
    updatePlayList()
  end

  local state = DeserializeSafe(Select(tParams, "state"))
  if type(state) ~= "table" then
    return
  end
  volumeState.online = state.online ~= false
  volumeState.on = state.on == true
  volumeState.brightnessPct = tonumber(state.brightnessPct) or volumeState.brightnessPct

  notifyOnline(volumeState.online)
  -- Report 0 while stopped so the load reads as off, but keep the last real
  -- volume in volumeState so ON can resume at it rather than jumping to full.
  notifyBrightness(volumeState.on and volumeState.brightnessPct or 0)
  UpdateProperty("Driver Status", volumeState.online and "Connected" or "Device offline")
end

--------------------------------------------------------------------------------
-- Proxy command handlers (light_v2 -> coordinator)
--------------------------------------------------------------------------------

function RFP.ON(idBinding)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local body = turnOnTarget() or {}
  body.command = "on"
  -- A sound carries no volume of its own, so start it at the dimmer's preset.
  -- A favorite brings its own volume and colour, so leave it alone.
  if not body.favoriteId then
    body.brightness = presetLevel()
  end
  log:debug(
    "Turn on: favorite=%s sound=%s volume=%s",
    tostring(body.favoriteId),
    tostring(body.soundId),
    tostring(body.brightness)
  )
  entityCommand(body)
end

function RFP.OFF(idBinding)
  if idBinding ~= PROXY_BINDING then
    return
  end
  entityCommand({ command = "off" })
end

function RFP.DYNAMIC_ON(idBinding)
  RFP.ON(idBinding)
end

function RFP.DYNAMIC_OFF(idBinding)
  RFP.OFF(idBinding)
end

function RFP.TOGGLE(idBinding)
  if idBinding ~= PROXY_BINDING then
    return
  end
  if volumeState.on then
    entityCommand({ command = "off" })
  else
    local body = turnOnTarget() or {}
    body.command = "on"
    if not body.favoriteId then
      body.brightness = presetLevel()
    end
    entityCommand(body)
  end
end

local function setBrightness(idBinding, level)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local pct = tonumber(level) or 0
  if pct < 0 then
    pct = 0
  elseif pct > 100 then
    pct = 100
  end
  -- Ramping to 0 is the user turning it off, not asking for silence. Leaving
  -- the volume alone means the next start is not silent.
  if pct <= 0 then
    entityCommand({ command = "off" })
    return
  end
  -- Navigator turns a dimmer on by sending a level rather than ON, so a level
  -- arriving while stopped IS the turn-on and has to start the chosen entry.
  if not volumeState.on then
    local body = turnOnTarget() or {}
    body.command = "on"
    if not body.favoriteId then
      body.brightness = pct
    end
    entityCommand(body)
    return
  end
  entityCommand({ command = "setBrightness", brightness = pct })
end

function RFP.GET_CONNECTED_STATE(idBinding)
  if idBinding ~= PROXY_BINDING then
    return
  end
  notifyOnline(volumeState.online)
end

function RFP.SET_LEVEL(idBinding, _strCommand, tParams)
  setBrightness(idBinding, Select(tParams, "LEVEL"))
end

function RFP.SET_BRIGHTNESS_TARGET(idBinding, _strCommand, tParams)
  setBrightness(idBinding, Select(tParams, "LIGHT_BRIGHTNESS_TARGET"))
end

function RFP.RAMP_TO_LEVEL(idBinding, _strCommand, tParams)
  setBrightness(idBinding, Select(tParams, "LEVEL"))
end

--------------------------------------------------------------------------------
-- Proxy command dispatch
--------------------------------------------------------------------------------

function ReceivedFromProxy(idBinding, strCommand, tParams)
  strCommand = strCommand or ""
  tParams = tParams or {}

  if idBinding == COORD_BINDING then
    if strCommand == "UPDATE_STATE" then
      applyState(tParams)
    elseif strCommand == "UPDATE_DISCONNECT" then
      volumeState.online = false
      notifyOnline(false)
      UpdateProperty("Driver Status", "Coordinator offline")
    end
    return
  end

  local handler = RFP[strCommand]
  if type(handler) == "function" then
    local ok, err = pcall(handler, idBinding, strCommand, tParams)
    if not ok then
      log:warn("Hatch volume command '%s' error: %s", strCommand, tostring(err))
    end
  end
end

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
  log:trace("OnDriverInit()")
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end
  gInitialized = true
  UpdateProperty("Driver Status", "Waiting for coordinator")
  -- Declare offline before asking for state, so nothing reads the proxy as
  -- reachable in the window before the coordinator answers.
  notifyOnline(false)
  SendToProxy(COORD_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end

--- Announce reachability on bind and retract it on unbind, per light_v2.
OBC = OBC or {}
OBC[COORD_BINDING] = function(_idBinding, _strClass, bIsBound)
  notifyOnline(bIsBound and volumeState.online)
  if bIsBound then
    SendToProxy(COORD_BINDING, "REFRESH_STATE", {}, "NOTIFY")
  end
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
end

--- Resolved at turn-on time, so nothing to do beyond letting Composer keep it.
function OPC.Turn_On_Plays(_v) end

function OPC.Driver_Status(_v) end

function OPC.Driver_Version(_v)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

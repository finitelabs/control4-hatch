-- Hatch Sound Machine companion.
--
-- Presents one Hatch device's sound machine as a Control4 media service +
-- amplifier endpoint. Owns no cloud connection: it binds to the Hatch account
-- coordinator (HATCH_MEDIA), receives its sound catalog + state as UPDATE_STATE,
-- and sends browse/play/volume actions to the coordinator as ENTITY_COMMAND.

--#ifdef DRIVERCENTRAL
DC_PID = 0 -- TODO: Assign DriverCentral product ID
DC_X = nil
DC_FILENAME = "hatch_media.c4z"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

JSON = require("JSON")

local log = require("lib.logging")

local PROXY_BINDING = 5001
local AMP_PROXY = 5002
local COORD_BINDING = 6001
local AUDIO_OUTPUT = "7001"
local VOLUME_STEP = 5

gInitialized = false

local sounds = {}
local soundsById = {}
local soundsByTitle = {}
local favorites = {}
--- soundId -> artwork url, covering sounds outside the browse catalog.
local artById = {}
local state = {}
local mutedVolume = nil
local wasPlaying = false
local reconciled = false
Navigators = Navigators or {}
Navigator = Navigator or {}

--------------------------------------------------------------------------------
-- Coordinator link
--------------------------------------------------------------------------------

--- Send an action to the coordinator, which maps it to a device shadow update.
local function entityCommand(body)
  SendToProxy(COORD_BINDING, "ENTITY_COMMAND", { body = SerializeSafe(body) }, "NOTIFY")
end

--- Select this media service as the room's audio source, which establishes the
--- Control4 listening session. Without it the sound plays on the Hatch but
--- Navigator shows no session to stop or adjust. deviceid is our media-service
--- proxy; Control4 resolves the path from there through the amplifier.
local function selectAudioIn(rooms)
  local deviceId = C4:GetProxyDevices()
  log:info("Hatch media: SELECT_AUDIO_DEVICE %s in rooms [%s]", tostring(deviceId), table.concat(rooms or {}, ","))
  for _, roomId in ipairs(rooms or {}) do
    C4:SendToDevice(roomId, "SELECT_AUDIO_DEVICE", { deviceid = deviceId })
  end
end

--- Resolve the room set for a start-media action: the picker result
--- (START_MEDIA_ROOMS, an array/map/comma-list) with a fallback to the nav
--- room the command came from.
local function parseRooms(extraRooms, fallbackRoom)
  local rooms = {}
  if type(extraRooms) == "table" then
    if #extraRooms > 0 then
      for _, r in ipairs(extraRooms) do
        local n = tonumber(r)
        if n then
          rooms[#rooms + 1] = n
        end
      end
    else
      for r, truthy in pairs(extraRooms) do
        local n = tonumber(r)
        if n and truthy and truthy ~= false and truthy ~= "false" and truthy ~= "0" then
          rooms[#rooms + 1] = n
        end
      end
    end
  elseif type(extraRooms) == "string" and extraRooms ~= "" then
    for r in extraRooms:gmatch("%d+") do
      rooms[#rooms + 1] = tonumber(r)
    end
  end
  if #rooms == 0 and fallbackRoom then
    local n = tonumber(fallbackRoom)
    if n then
      rooms[#rooms + 1] = n
    end
  end
  return rooms
end

--------------------------------------------------------------------------------
-- Media service protocol helpers
--------------------------------------------------------------------------------

local function DataReceived(idBinding, navId, seq, data)
  local payload = ""
  if type(data) == "string" then
    payload = data
  elseif type(data) == "table" then
    payload = XMLTag(nil, data, false, false)
  end
  C4:SendToProxy(idBinding, "DATA_RECEIVED", { NAVID = navId, SEQ = seq, DATA = payload })
end

local function DataReceivedError(idBinding, navId, seq, msg)
  C4:SendToProxy(idBinding, "DATA_RECEIVED", { NAVID = navId, SEQ = seq, DATA = "", ERROR = tostring(msg) })
end

local function updateNowPlaying(title, subtitle, imageUrl)
  -- The media_service proxy expects these exact UPPERCASE keys (mediaTitle etc.
  -- are silently ignored, which is why the session showed no now-playing).
  -- IMAGEURL must be base64-encoded. Mirrors WiiM Pro / SiriusXM.
  C4:SendToProxy(PROXY_BINDING, "UPDATE_MEDIA_INFO", {
    TITLE = title or "",
    ARTIST = subtitle or "",
    ALBUM = "",
    GENRE = "",
    IMAGEURL = (imageUrl and imageUrl ~= "") and C4:Base64Encode(imageUrl) or "",
  }, "COMMAND", true)
end

local function notifyVolume(pct)
  C4:SendToProxy(AMP_PROXY, "VOLUME_LEVEL_CHANGED", { OUTPUT = AUDIO_OUTPUT, LEVEL = tonumber(pct) or 0 }, "NOTIFY")
end

local function notifyMute(muted)
  C4:SendToProxy(AMP_PROXY, "MUTE_CHANGED", { OUTPUT = AUDIO_OUTPUT, MUTE = muted and "true" or "false" }, "NOTIFY")
end

--------------------------------------------------------------------------------
-- State from coordinator
--------------------------------------------------------------------------------

local function applyState(tParams)
  local newSounds = DeserializeSafe(Select(tParams, "sounds"))
  if type(newSounds) == "table" then
    sounds = newSounds
    soundsById = {}
    soundsByTitle = {}
    for _, s in ipairs(sounds) do
      soundsById[tostring(s.id)] = s
      if s.title then
        soundsByTitle[s.title] = s
      end
    end
  end
  local newFavorites = DeserializeSafe(Select(tParams, "favorites"))
  if type(newFavorites) == "table" then
    favorites = newFavorites
  end
  local newArtwork = DeserializeSafe(Select(tParams, "artwork"))
  if type(newArtwork) == "table" then
    artById = newArtwork
  end

  state = DeserializeSafe(Select(tParams, "state")) or {}

  -- Keep the room session in sync with device-initiated playback: select
  -- ourselves when playback starts, release the room when it stops. `selected`
  -- is the room's CURRENT_SELECTED_AUDIO_DEVICE; `mine` is our proxy device.
  local nowPlaying = state.isPlaying == true
  local room = tonumber(C4:RoomGetId())
  local selected = room and tostring(C4:GetDeviceVariable(room, 1001))
  local mine = tostring(C4:GetProxyDevices())
  if not reconciled then
    -- First state after a (re)load: wasPlaying is false, so the transition
    -- logic below can't reconcile a selection made before the reload. Sync both
    -- directions once -- surface a live session that lost its card, or release
    -- a strand left selected with nothing playing.
    reconciled = true
    if nowPlaying then
      if selected == "0" then
        selectAudioIn({ room })
      end
    elseif selected == mine then
      C4:SendToDevice(room, "ROOM_OFF", {})
    end
  elseif nowPlaying and not wasPlaying then
    -- Device-initiated play: select our room only if its audio is off, so we
    -- never steal a room already listening to something else (a no-op when a
    -- Control4-initiated play already pre-selected us).
    if selected == "0" then
      selectAudioIn({ room })
    end
  elseif wasPlaying and not nowPlaying then
    -- Playback stopped, often externally (Hatch app, touch ring, or the device
    -- dropping offline). If we're still the selected source, end the session so
    -- C4 doesn't leave a ghost "Off" now-playing card up.
    if selected == mine then
      C4:SendToDevice(room, "ROOM_OFF", {})
    end
  end
  wasPlaying = nowPlaying

  -- Distinguish a device that's unreachable ("Offline") from one that's simply
  -- idle ("Off"), so a dropped/unplugged Hatch reads clearly instead of looking
  -- like nothing is selected.
  local title
  if state.online == false then
    title = "Offline"
  elseif state.isPlaying then
    title = state.soundTitle or ("Sound " .. tostring(state.soundId))
  else
    title = "Off"
  end
  -- Cover art only while something is actually playing; "Off"/"Offline" fall
  -- back to the driver icon rather than showing the last sound's artwork.
  updateNowPlaying(title, state.isPlaying and "Hatch" or nil, state.isPlaying and state.soundImage or nil)
  if state.volumePct then
    notifyVolume(state.volumePct)
  end
  UpdateProperty("Driver Status", state.online == false and "Device offline" or "Connected")
end

--- Display labels for the favorites list. The Hatch app allows duplicate names
--- (two "Brown Noise" favorites differing only in volume/color) and the API
--- carries no other label, so repeats get an occurrence counter. Indexed to
--- line up with the favorites array.
local function favoriteLabels()
  local totals = {}
  for _, fav in ipairs(favorites) do
    local name = fav.name or ("Favorite " .. tostring(fav.id))
    totals[name] = (totals[name] or 0) + 1
  end
  local seen, labels = {}, {}
  for i, fav in ipairs(favorites) do
    local name = fav.name or ("Favorite " .. tostring(fav.id))
    if (totals[name] or 0) > 1 then
      seen[name] = (seen[name] or 0) + 1
      labels[i] = string.format("%s (%d)", name, seen[name])
    else
      labels[i] = name
    end
  end
  return labels
end

--------------------------------------------------------------------------------
-- Navigator (browse screens render from the coordinator-supplied catalog)
--------------------------------------------------------------------------------

function Navigator:new(navId)
  local nav = { navId = navId }
  setmetatable(nav, { __index = self })
  return nav
end

function Navigator:GetTabList()
  local tabs = {
    XMLTag("Tab", { Name = "Sounds", Id = "Sounds", ScreenId = "SoundsScreen" }),
    XMLTag("Tab", { Name = "Favorites", Id = "Favorites", ScreenId = "FavoritesScreen" }),
  }
  return { Tabs = table.concat(tabs) }
end

function Navigator:BrowseSounds()
  local list = {}
  for _, sound in ipairs(sounds) do
    list[#list + 1] = XMLTag("item", {
      title = sound.title,
      soundId = tostring(sound.id),
      -- Omitted when the sound has no artwork, which leaves the row's default.
      image_list = sound.image,
      default_action = "PlaySound",
      actions_list = "PlaySound",
    })
  end
  return { List = table.concat(list) }
end

--- A favorite has no artwork of its own, so it borrows the art of the first
--- sound its routine plays. Returns nil when no step names a sound we have.
local function favoriteImage(fav)
  for _, step in ipairs(fav.steps or {}) do
    local id = step.sound and step.sound.id
    if id then
      local key = tostring(id)
      local sound = soundsById[key]
      local art = (sound and sound.image) or artById[key]
      if art then
        return art
      end
    end
  end
  return nil
end

function Navigator:BrowseFavorites()
  local labels = favoriteLabels()
  local list = {}
  for i, fav in ipairs(favorites) do
    list[#list + 1] = XMLTag("item", {
      title = labels[i],
      favoriteId = tostring(fav.id),
      image_list = favoriteImage(fav),
      default_action = "PlayFavorite",
      actions_list = "PlayFavorite",
    })
  end
  return { List = table.concat(list) }
end

function Navigator:PlaySound(_idBinding, _seq, args)
  if args and args.soundId then
    selectAudioIn(parseRooms(args.extraRooms, self.roomId))
    entityCommand({ command = "play", soundId = args.soundId })
  end
end

function Navigator:PlayFavorite(_idBinding, _seq, args)
  if args and args.favoriteId then
    selectAudioIn(parseRooms(args.extraRooms, self.roomId))
    entityCommand({ command = "favorite", favoriteId = args.favoriteId })
  end
end

--------------------------------------------------------------------------------
-- Proxy command dispatch
--------------------------------------------------------------------------------

function ReceivedFromProxy(idBinding, strCommand, tParams)
  strCommand = strCommand or ""
  tParams = tParams or {}

  -- State pushed from the coordinator.
  if idBinding == COORD_BINDING then
    if strCommand == "UPDATE_STATE" then
      applyState(tParams)
    elseif strCommand == "UPDATE_DISCONNECT" then
      UpdateProperty("Driver Status", "Coordinator offline")
    end
    return
  end

  local args = {}
  if tParams.ARGS then
    local ok, parsed = pcall(function()
      return C4:ParseXml(tParams.ARGS)
    end)
    if ok and parsed and parsed.ChildNodes then
      for _, node in pairs(parsed.ChildNodes) do
        if node.Attributes and node.Attributes.name then
          args[node.Attributes.name] = node.Value
        end
      end
    end
    tParams.ARGS = nil
  end

  -- Transport + amplifier commands.
  if strCommand == "PLAY" then
    if state.soundId then
      entityCommand({ command = "play", soundId = state.soundId })
    end
    return
  elseif strCommand == "STOP" or strCommand == "PAUSE" or strCommand == "OFF" then
    entityCommand({ command = "stop" })
    return
  elseif strCommand == "SET_VOLUME_LEVEL" then
    local level = tonumber(tParams.LEVEL or tParams.Volume or tParams.VOLUME)
    if level then
      entityCommand({ command = "volume", level = level })
      notifyVolume(level)
    end
    return
  elseif strCommand == "PULSE_VOL_UP" or strCommand == "PULSE_VOL_DOWN" then
    local current = state.volumePct or 0
    local level = strCommand == "PULSE_VOL_UP" and math.min(100, current + VOLUME_STEP)
      or math.max(0, current - VOLUME_STEP)
    entityCommand({ command = "volume", level = level })
    notifyVolume(level)
    return
  elseif strCommand == "MUTE_ON" or strCommand == "MUTE_OFF" or strCommand == "MUTE_TOGGLE" then
    local muted = strCommand == "MUTE_ON" or (strCommand == "MUTE_TOGGLE" and mutedVolume == nil)
    if muted then
      mutedVolume = state.volumePct or 25
      entityCommand({ command = "volume", level = 0 })
      notifyVolume(0)
    else
      local restore = mutedVolume or 25
      mutedVolume = nil
      entityCommand({ command = "volume", level = restore })
      notifyVolume(restore)
    end
    notifyMute(muted)
    return
  end

  -- Navigator (browse) commands.
  local navId = tParams.NAVID
  local seq = tParams.SEQ
  if navId then
    local nav = Navigators[navId] or Navigator:new(navId)
    Navigators[navId] = nav
    nav.roomId = tonumber(tParams.ROOMID)
    local cmd = nav[strCommand]
    if type(cmd) == "function" then
      local ok, ret = pcall(cmd, nav, idBinding, seq, args)
      if ok then
        if ret then
          DataReceived(idBinding, navId, seq, ret)
        end
      else
        log:warn("Hatch media nav '%s' error: %s", strCommand, tostring(ret))
        DataReceivedError(idBinding, navId, seq, ret)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Programming (GCPL lists + EC commands)
--------------------------------------------------------------------------------

-- Composer command lists (GetCommandParamList) render a plain array of strings;
-- the selected string comes back verbatim as the command parameter. So we list
-- titles/labels here and resolve them back to ids in the EC handlers below.
function GCPL.Play_Sound()
  local list = {}
  for _, sound in ipairs(sounds) do
    list[#list + 1] = sound.title
  end
  return list
end

function GCPL.Play_Favorite()
  return favoriteLabels()
end

function EC.Play_Sound(params)
  local sound = params and params.Sound and soundsByTitle[params.Sound]
  if sound then
    entityCommand({ command = "play", soundId = sound.id })
  end
end

function EC.Play_Favorite(params)
  local label = params and params.Favorite
  if not label then
    return
  end
  -- Resolve the (de-duplicated) label back to a favorite id.
  local labels = favoriteLabels()
  for i, l in ipairs(labels) do
    if l == label then
      entityCommand({ command = "favorite", favoriteId = favorites[i].id })
      return
    end
  end
end

function EC.Stop(_params)
  entityCommand({ command = "stop" })
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

--- Hide the amplifier child from every Navigator. It holds the room's
--- AUDIO_SELECTION binding, which is what makes Control4 list it as an audio
--- source alongside the real one; no driver capability suppresses that
--- (hide_in_list_nav, allow_as_path_source and audiosource were all tested), so
--- it is hidden at runtime. Runs every init: a re-add mints a new device id.
local function hideAmplifierFromNavigators()
  local ampId = C4:GetBoundPartner(C4:GetDeviceID(), AMP_PROXY, "AVSWITCH")
  if not ampId or ampId == 0 then
    log:debug("Amplifier child not resolved yet; nothing to hide")
    return
  end
  local rooms = C4:GetDevicesByC4iName("roomdevice.c4i") or {}
  local count = 0
  for roomId, _ in pairs(rooms) do
    C4:SendToDevice(roomId, "SET_DEVICE_HIDDEN_STATE", {
      PROXY_GROUP = "ALL",
      DEVICE_ID = ampId,
      IS_HIDDEN = true,
    })
    count = count + 1
  end
  log:info("Hid amplifier child (device %s) from %d navigator room(s)", tostring(ampId), count)
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
  UpdateProperty("Driver Status", "Ready")
  pcall(hideAmplifierFromNavigators)
  SendToProxy(COORD_BINDING, "REFRESH_STATE", {}, "NOTIFY")
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

function OPC.Driver_Status(_v) end

function OPC.Driver_Version(_v)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

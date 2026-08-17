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

JSON = require("JSON")

local log = require("lib.logging")
local conditionals = require("lib.conditionals")
local Favorites = require("hatch.favorites")

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
--- Defined below, but the conditionals need it before that point.
local favoriteLabels
Navigators = Navigators or {}
Navigator = Navigator or {}

--- Playback state we've committed to (last command sent, or adopted on reload).
--- A reload re-pushes stale state, so a contradicting update is dropped below.
local pendingIntent = nil
local INTENT_WINDOW = 8 * ONE_SECOND

local function setIntent(playing)
  pendingIntent = playing and true or false
  SetTimer("PlaybackIntent", INTENT_WINDOW, function()
    pendingIntent = nil
  end)
end

--------------------------------------------------------------------------------
-- Coordinator link
--------------------------------------------------------------------------------

--- Send an action to the coordinator, which maps it to a device shadow update.
local function entityCommand(body)
  if body then
    if body.command == "stop" then
      setIntent(false)
    elseif body.command == "play" or body.command == "favorite" then
      setIntent(true)
    end
  end
  SendToProxy(COORD_BINDING, "ENTITY_COMMAND", { body = SerializeSafe(body) }, "NOTIFY")
end

-- Room source arbitration, and the two facts the rest of this section rests on.
--
-- Control4 switches a room's routing on its own but never stops the source it
-- switched away from: ordinary gear falls silent once the room stops routing
-- it, while the Hatch renders its own audio and keeps playing unheard. So the
-- driver has to translate "you were deselected" into "actually stop".
--
-- ROOM_OFF is the only command that clears a room's audio session. deviceid=0
-- and every AUDIO_OFF/DESELECT spelling were tried against a live room and are
-- silent no-ops. It takes the whole room down, so every use of it below is
-- guarded.

--- The foreground device. Deliberately not CURRENT_AUDIO_DEVICE (1001), which a
--- video source never touches, so watching that one misses a switch to the TV.
local ROOM_VAR_SELECTED_DEVICE = 1000
local ROOM_VAR_POWER_STATE = 1010

--- An off room has no session to end, and ROOM_OFF re-broadcasts power to its
--- devices: a TV with toggle power reads a second off as "turn on".
local function roomIsOff(room)
  return room ~= nil and tostring(C4:GetDeviceVariable(room, ROOM_VAR_POWER_STATE)) == "0"
end

--- True when nothing else holds the room. Reads the foreground device, not
--- CURRENT_AUDIO_DEVICE, which a video source never sets.
local function roomIsFree(room)
  if room == nil then
    return false
  end
  return tostring(C4:GetDeviceVariable(room, ROOM_VAR_SELECTED_DEVICE)) == "0"
end

--- Set while we stop ourselves because another source took the room, so the
--- resulting stop does not release a room we no longer own. Time-limited: if
--- that stop never arrives (device offline, or the app restarts playback first)
--- a stuck flag would suppress the next real release and leave a ghost session.
local yieldingRoom = false
local YIELD_WINDOW = 30 * ONE_SECOND

local function beginYield()
  yieldingRoom = true
  SetTimer("YieldRoom", YIELD_WINDOW, function()
    yieldingRoom = false
  end)
end

local function endYield()
  yieldingRoom = false
  CancelTimer("YieldRoom")
end

--- Select this media service as the room's audio source, establishing the
--- listening session. Without it the sound plays on the Hatch but Navigator
--- shows nothing to stop or adjust. Taking a room another source holds means
--- turning it off first.
local function selectAudioIn(rooms)
  local deviceId = C4:GetProxyDevices()
  log:info("Hatch media: SELECT_AUDIO_DEVICE %s in rooms [%s]", tostring(deviceId), table.concat(rooms or {}, ","))
  for _, roomId in ipairs(rooms or {}) do
    local holder = tostring(C4:GetDeviceVariable(roomId, ROOM_VAR_SELECTED_DEVICE))
    if holder ~= "0" and holder ~= tostring(deviceId) and not roomIsOff(roomId) then
      log:info("Room %s held by device %s; taking it", tostring(roomId), holder)
      C4:SendToDevice(roomId, "ROOM_OFF", {})
    end
    C4:SendToDevice(roomId, "SELECT_AUDIO_DEVICE", { deviceid = deviceId })
  end
end

--- Stop playback when the room's audio moves to another source, so whichever
--- source was picked last is the one playing.
local function watchRoomSelection()
  local room = tonumber(C4:RoomGetId())
  if not room then
    return
  end
  RegisterVariableListener(room, ROOM_VAR_SELECTED_DEVICE, function(_idDevice, _idVariable, strValue)
    local selectedNow = tostring(strValue)
    local mine = tostring(C4:GetProxyDevices())
    -- 0 means the room went off, which already reaches us as a proxy OFF; only
    -- act on a switch to a different source.
    if selectedNow == "0" or selectedNow == mine then
      return
    end
    if state.isPlaying == true then
      log:info("Room %s switched to device %s; stopping", tostring(room), selectedNow)
      -- The new source already owns the room. Releasing on the way out would
      -- send ROOM_OFF and turn off the source that just took over.
      beginYield()
      entityCommand({ command = "stop" })
    end
  end)
  log:debug("Watching room %s selected device", tostring(room))
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

--- Last volume reported to the proxy. Every shadow update pushes state and
--- SET_VOLUME_LEVEL reports optimistically, so without this the volume is
--- re-notified constantly and anything programming against it fires on every
--- push rather than on real changes.
local lastVolumeNotified = nil

local function notifyVolume(pct)
  pct = tonumber(pct) or 0
  if lastVolumeNotified == pct then
    return
  end
  lastVolumeNotified = pct
  C4:SendToProxy(AMP_PROXY, "VOLUME_LEVEL_CHANGED", { OUTPUT = AUDIO_OUTPUT, LEVEL = pct }, "NOTIFY")
end

local function notifyMute(muted)
  C4:SendToProxy(AMP_PROXY, "MUTE_CHANGED", { OUTPUT = AUDIO_OUTPUT, MUTE = muted and "true" or "false" }, "NOTIFY")
end

--------------------------------------------------------------------------------
-- Programming conditionals
--------------------------------------------------------------------------------

local CONDITIONALS_NS = "HatchMedia"

local function currentSoundTitle()
  if state.isPlaying ~= true then
    return nil
  end
  return state.soundTitle
end

--- Favorite currently playing, or nil when idle or playing a plain sound.
local function currentFavoriteLabel()
  if state.isPlaying ~= true or state.favoriteId == nil then
    return nil
  end
  local labels = favoriteLabels()
  for i, fav in ipairs(favorites) do
    if tostring(fav.id) == tostring(state.favoriteId) then
      return labels[i]
    end
  end
  return nil
end

--- Compare the live value against the programmer's choice. Nothing playing
--- matches nothing, so an idle device fails an EQUAL test and passes NOT_EQUAL.
local function conditionalMatches(current, tParams)
  local matched = current ~= nil and Favorites.listSafe(current) == Select(tParams, "VALUE")
  if Select(tParams, "LOGIC") == "NOT_EQUAL" then
    return not matched
  end
  return matched
end

--- (Re)register the conditionals, whose item lists come from the catalog and so
--- are not known at startup. Every state push carries the catalog, so the
--- signature keeps an unchanged one from being rewritten and persisted on every
--- volume report.
local lastConditionalSignature = nil

local function registerConditionals()
  local titlesSig = {}
  for _, sound in ipairs(sounds) do
    titlesSig[#titlesSig + 1] = tostring(sound.title)
  end
  for _, label in ipairs(favoriteLabels()) do
    titlesSig[#titlesSig + 1] = tostring(label)
  end
  local signature = table.concat(titlesSig, "\30")
  if signature == lastConditionalSignature then
    return
  end
  lastConditionalSignature = signature

  -- Independent of the catalog, so this works before any sounds arrive.
  conditionals:upsertConditional(CONDITIONALS_NS, "is_playing", {
    type = "BOOL",
    condition_statement = "Playback state",
    description = "NAME is STRING",
    true_text = "Playing",
    false_text = "Stopped",
  }, function(_strConditionName, tParams)
    local isPlaying = state.isPlaying == true
    local test = Select(tParams, "VALUE") == "Playing"
    if Select(tParams, "LOGIC") == "NOT_EQUAL" then
      return test ~= isPlaying
    end
    return test == isPlaying
  end)

  local titles = {}
  for _, sound in ipairs(sounds) do
    if sound.title then
      titles[#titles + 1] = Favorites.listSafe(sound.title)
    end
  end
  conditionals:upsertConditional(CONDITIONALS_NS, "current_sound", {
    type = "LIST",
    condition_statement = "Current sound",
    description = "the sound playing on NAME is LOGIC STRING",
    list_items = table.concat(titles, ","),
  }, function(_strConditionName, tParams)
    return conditionalMatches(currentSoundTitle(), tParams)
  end)

  local labels = {}
  for _, label in ipairs(favoriteLabels()) do
    labels[#labels + 1] = Favorites.listSafe(label)
  end
  conditionals:upsertConditional(CONDITIONALS_NS, "current_favorite", {
    type = "LIST",
    condition_statement = "Current favorite",
    description = "the favorite playing on NAME is LOGIC STRING",
    list_items = table.concat(labels, ","),
  }, function(_strConditionName, tParams)
    return conditionalMatches(currentFavoriteLabel(), tParams)
  end)

  log:debug("Registered conditionals: %d sound(s), %d favorite(s)", #titles, #labels)
end

--------------------------------------------------------------------------------
-- State from coordinator
--------------------------------------------------------------------------------

local function applyState(tParams)
  local catalogChanged = false
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
    catalogChanged = true
  end
  local newFavorites = DeserializeSafe(Select(tParams, "favorites"))
  if type(newFavorites) == "table" then
    favorites = newFavorites
    catalogChanged = true
  end
  local newArtwork = DeserializeSafe(Select(tParams, "artwork"))
  if type(newArtwork) == "table" then
    artById = newArtwork
  end
  if catalogChanged then
    registerConditionals()
  end

  local incoming = DeserializeSafe(Select(tParams, "state")) or {}
  local nowPlaying = incoming.isPlaying == true

  -- A reported state contradicting our committed intent is a stale reload echo;
  -- acting on it re-arbitrates the room and stops us. Leave the last state in place.
  if pendingIntent ~= nil and nowPlaying ~= pendingIntent then
    return
  end

  state = incoming

  -- Keep the room session in sync with device-initiated playback: select
  -- ourselves when playback starts, release the room when it stops. `selected`
  -- is the room's CURRENT_SELECTED_AUDIO_DEVICE; `mine` is our proxy device.
  local room = tonumber(C4:RoomGetId())
  local selected = room and tostring(C4:GetDeviceVariable(room, 1001))
  local mine = tostring(C4:GetProxyDevices())

  --- End the room session when we hold it, so Navigator does not leave a session
  --- reading "Off". Each guard below is a room we must not take down.
  local function releaseRoom()
    if selected ~= mine then
      return
    end
    -- Something else took the room; this stop is us getting out of its way.
    if yieldingRoom then
      log:debug("Yielded room %s to another source; not releasing", tostring(room))
      return
    end
    -- CURRENT_AUDIO_DEVICE can still point at us while a video source holds the
    -- foreground, since a video source never clears it.
    local foreground = room and tostring(C4:GetDeviceVariable(room, ROOM_VAR_SELECTED_DEVICE))
    if foreground and foreground ~= "0" and foreground ~= mine then
      log:debug("Room %s now on device %s; not releasing", tostring(room), foreground)
      return
    end
    -- Usually this stop is the tail of a room-off the user just pressed.
    if roomIsOff(room) then
      log:debug("Room %s already off; not releasing", tostring(room))
      return
    end
    log:debug("Releasing room %s", tostring(room))
    C4:SendToDevice(room, "ROOM_OFF", {})
  end

  if not reconciled then
    -- First state after a (re)load: reconcile once. Commit to it so the
    -- reconnect's re-push can't flap the room, then restore the session if
    -- playing (the room's vars still point at us) or release a dead strand.
    reconciled = true
    setIntent(nowPlaying)
    if nowPlaying then
      local foreground = room and tostring(C4:GetDeviceVariable(room, ROOM_VAR_SELECTED_DEVICE))
      if roomIsFree(room) or foreground == mine then
        selectAudioIn({ room })
      end
    else
      releaseRoom()
    end
  elseif nowPlaying and not wasPlaying then
    C4:FireEvent("Started Playing")
    -- The device started itself, so only claim a free room. Taking one sends
    -- ROOM_OFF, which stays reserved for the user picking the Hatch in Control4.
    if selected == "0" and roomIsFree(room) then
      selectAudioIn({ room })
    end
  elseif wasPlaying and not nowPlaying then
    C4:FireEvent("Stopped Playing")
    -- Playback stopped, often externally (Hatch app, touch ring, or the device
    -- dropping offline). If we're still the selected source, end the session so
    -- C4 doesn't leave a ghost "Off" now-playing card up.
    releaseRoom()
    endYield()
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

--- Display labels for the favorites list, indexed to line up with the favorites
--- array. Shared with the volume dimmer so both render the same names.
function favoriteLabels()
  return Favorites.labels(favorites)
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
      -- Mark the cached state unreachable rather than only relabelling the
      -- property. Left alone it keeps feeding the now-playing card and the
      -- conditionals, so Navigator shows the last sound and programming still
      -- answers "yes, playing" while the account has no cloud connection.
      state.online = false
      state.isPlaying = false
      -- Deliberately NOT touching wasPlaying: it is the event stream's memory of
      -- what it last announced, not device state. Clearing it would announce a
      -- Started Playing on reconnect for a device that never stopped, and swallow
      -- the Stopped Playing (and its room release) if it stopped during the drop.
      updateNowPlaying("Offline")
      lastVolumeNotified = nil
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
  local favorite = Favorites.byLabel(favorites, params and params.Favorite)
  if favorite then
    entityCommand({ command = "favorite", favoriteId = favorite.id })
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
  pcall(watchRoomSelection)
  -- Register up front so the conditionals exist in Composer before any catalog
  -- arrives; the sound and favorite lists fill in when the coordinator pushes.
  registerConditionals()
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

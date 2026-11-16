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
-- own writes, which Programming has no way to express. The dimmer is the
-- light_v2 proxy on binding 5001, run by the light library (lib.light) through
-- the volume adapter (src/hatch/volume_adapter.lua).

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local constants = require("constants")
local Favorites = require("hatch.favorites")
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
local updateSettings = require("lib.update-settings")
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif

local Light = require("lib.light")
local VolumeAdapter = require("hatch.volume_adapter")

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

--------------------------------------------------------------------------------
-- Coordinator link
--------------------------------------------------------------------------------

local function entityCommand(body)
  SendToProxy(COORD_BINDING, "ENTITY_COMMAND", { body = SerializeSafe(body) }, "NOTIFY")
end

--- Ask the coordinator for the device's state.
local function refresh()
  SendToProxy(COORD_BINDING, "REFRESH_STATE", {}, "NOTIFY")
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

--- Resolve the installer's choice to something the coordinator can play.
--- @return HatchVolumeTarget|nil target What On plays, or nil to resume the last sound.
local function turnOnTarget()
  local choice = Properties["Turn On Plays"]
  if not choice or choice == "" or choice == constants.SELECT_OPTION then
    -- Nothing chosen yet. Falls through to resuming the last sound only when
    -- the account has no favorites at all.
    local first = favorites[1]
    if first and first.id then
      return { favoriteId = first.id, favorite = first }
    end
    return nil
  end
  local favLabel = choice:match("^" .. FAVORITE_PREFIX .. "(.+)$")
  if favLabel then
    for index, label in ipairs(Favorites.labels(favorites)) do
      if Favorites.listSafe(label) == favLabel then
        return { favoriteId = favorites[index].id, favorite = favorites[index] }
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

local volume = VolumeAdapter:new({ send = entityCommand, refresh = refresh, target = turnOnTarget })

--- The volume: a dimmer with no color and no fades. No Button Links, scenes or on modes, and an ON resumes the
--- device's own volume.
--- @type LightProfile
local PROFILE = {
  api = Light.API,
  dims = true,
  known = true,
}

local light = Light.new(volume, PROFILE)

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
  local online = state.online ~= false
  UpdateProperty("Driver Status", online and "Connected" or "Device offline")
  if not online then
    -- A device Hatch has lost reads off.
    volume:forget()
    light:lost(false)
    return
  end
  light:declare(VolumeAdapter.DEVICE)
  light:report(volume:report(state))
end

RFP[COORD_BINDING] = function(_idBinding, strCommand, tParams)
  if strCommand == "UPDATE_STATE" then
    applyState(tParams)
  elseif strCommand == "UPDATE_DISCONNECT" then
    UpdateProperty("Driver Status", "Coordinator offline")
    -- A lost link to Hatch reads off. The account's own stop leaves the volume as it was, and its next report tells
    -- it.
    volume:forget()
    light:lost(toboolean(Select(tParams, "suspended")))
  end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  drivercentral:startClient()
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
  -- The router runs each handler in its own xpcall and reports its error, so the rest still run.
  for p, _ in pairs(Properties) do
    OnPropertyChanged(p)
  end
  gInitialized = true
  UpdateProperty("Driver Status", "Waiting for coordinator")
  -- Offline until the coordinator answers the ask start makes.
  light:start()
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

--- A binding change: the device bound next tells its own state, and the proxy keeps the level it shows until then.
OBC = OBC or {}
OBC[COORD_BINDING] = function(_idBinding, _strClass, bIsBound)
  volume:forget()
  -- At a controller start this runs before late init, whose start tells offline itself.
  if gInitialized then
    light:lost(true)
  end
  if bIsBound then
    refresh()
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

--#ifdef DRIVERCENTRAL
function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  if gInitialized then
    updateSettings:share("Automatic Updates", propertyValue)
  end
end

--- An update setting changed on another item.
function EC.SET_UPDATE_SETTING(params)
  log:trace("EC.SET_UPDATE_SETTING(%s)", params)
  updateSettings:take(params)
end

--- Not logged: the value is the code.
function OPC.Support_Code(propertyValue)
  supportCode:enter(propertyValue)
end

--- Turns Cloud Monitoring on or off.
--- @param propertyValue string
function OPC.Cloud_Monitoring(propertyValue)
  diagnostics:setEnabled(propertyValue == "Enabled")
end

--- Prints a diagnostics report, and sends it while Cloud Monitoring is on.
function EC.DiagnosticsSnapshot()
  diagnostics:dumpSnapshot()
end
--#endif

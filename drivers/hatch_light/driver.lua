-- Hatch Night Light companion.
--
-- Presents one Hatch device's RGB night light as a Control4 light_v2 light.
-- Owns no cloud connection: it binds to the Hatch account coordinator
-- (HATCH_LIGHT), receives the device's state as UPDATE_STATE, and sends its
-- commands to the coordinator as ENTITY_COMMAND. The light is the light_v2
-- proxy on binding 5001, run by the light library (lib.light) through the
-- night light adapter (src/hatch/light_adapter.lua).

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
local updateSettings = require("lib.update-settings")
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif

local Light = require("lib.light")
local LightAdapter = require("hatch.light_adapter")

local COORD_BINDING = 5002

gInitialized = false

--------------------------------------------------------------------------------
-- Coordinator link
--------------------------------------------------------------------------------

--- Send an action to the coordinator, which maps it to a device shadow update.
local function entityCommand(body)
  SendToProxy(COORD_BINDING, "ENTITY_COMMAND", { body = SerializeSafe(body) }, "NOTIFY")
end

--- Ask the coordinator for the device's state.
local function refresh()
  SendToProxy(COORD_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end

local nightLight = LightAdapter:new({ send = entityCommand, refresh = refresh })

--- The night light: color without color temperature and no fades. No Button Links, scenes or on modes, and an ON
--- resumes the device's own level.
--- @type LightProfile
local PROFILE = {
  api = Light.API,
  dims = true,
  color = true,
  known = true,
}

local light = Light.new(nightLight, PROFILE)

--------------------------------------------------------------------------------
-- State from coordinator
--------------------------------------------------------------------------------

local function applyState(tParams)
  local state = DeserializeSafe(Select(tParams, "state"))
  if type(state) ~= "table" then
    return
  end
  local online = state.online ~= false
  UpdateProperty("Driver Status", online and "Connected" or "Device offline")
  if not online then
    -- A device Hatch has lost reads off.
    nightLight:forget()
    light:lost(false)
    return
  end
  light:declare(LightAdapter.DEVICE)
  light:report(nightLight:report(state))
end

RFP[COORD_BINDING] = function(_idBinding, strCommand, tParams)
  if strCommand == "UPDATE_STATE" then
    applyState(tParams)
  elseif strCommand == "UPDATE_DISCONNECT" then
    UpdateProperty("Driver Status", "Coordinator offline")
    -- A lost link to Hatch reads off. The account's own stop leaves the light as it was, and its next report tells it.
    nightLight:forget()
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
  nightLight:forget()
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

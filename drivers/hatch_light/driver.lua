-- Hatch Night Light companion.
--
-- Presents one Hatch device's RGB night light as a Control4 light_v2 proxy, through the shared
-- light library (lib.light): this driver is its adapter. It owns no cloud connection: it binds to
-- the Hatch account coordinator (HATCH_LIGHT), receives the light's on, color and brightness as
-- UPDATE_STATE, and sends on, off, color and brightness to the coordinator as ENTITY_COMMAND.
--
-- Color crosses the boundary as RGB (0-255) through Control4's converters; the library speaks CIE xy.
-- Brightness is a 0-100 percentage on the wire and 0 to 1 in the library.

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local Light = require("lib.light")
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
local updateSettings = require("lib.update-settings")
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif

local COORD_BINDING = 5002

gInitialized = false

--------------------------------------------------------------------------------
-- The adapter
--------------------------------------------------------------------------------

-- What the night light can do: an RGB light that changes at once. The account's cloud answers a
-- command with the state it now holds, but can first push the state it held before, so its reports
-- are judged against the commands sent (echo), waiting a while for the answer.
local DECLARATION = {
  dims = true,
  color = true,
  levelSteps = 100,
  fade = { by = "none" },
  reports = { policy = "echo", waitMs = 5000 },
}

--- Send an action to the coordinator, which maps it to a device shadow update.
local function entityCommand(body)
  SendToProxy(COORD_BINDING, "ENTITY_COMMAND", { body = SerializeSafe(body) }, "NOTIFY")
end

local function channel(v)
  return math.max(0, math.min(255, math.floor((tonumber(v) or 0) + 0.5)))
end

--- The night light's RGB for a color.
--- @param color LightColor
--- @return integer red, integer green, integer blue
local function rgbOf(color)
  local red, green, blue = C4:ColorXYtoRGB(color.x, color.y)
  return channel(red), channel(green), channel(blue)
end

local adapter = {}

-- A color sent while the light is off: the night light cannot take one without lighting, so the
-- next on carries it.
local heldColor = nil

--- Put a command on the wire. The night light changes at once, so a command's time is not sent.
--- @param cmd LightCommand
function adapter:send(cmd)
  if cmd.on == false then
    if cmd.color == nil then
      entityCommand({ command = "off" })
    else
      heldColor = cmd.color
    end
    return
  end
  local color = cmd.color or heldColor
  heldColor = nil
  local body = { command = "on" }
  if cmd.level then
    body = { command = "setBrightness", brightness = math.max(1, math.floor(cmd.level * 100 + 0.5)) }
  end
  if color then
    body.red, body.green, body.blue = rgbOf(color)
  end
  entityCommand(body)
end

--- Ask the coordinator for the light's whole state.
function adapter:refresh()
  SendToProxy(COORD_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end

--- The color the night light shows for one asked: the nearest it can make in RGB.
--- @param color LightColor
--- @return LightColor
function adapter:shows(color)
  local x, y = C4:ColorRGBtoXY(rgbOf(color))
  return { x = x, y = y, mode = Light.FULL }
end

-- Every Hatch night light is the same RGB light.
local light = Light.new(adapter, {
  api = 1,
  profile = { dims = true, color = true, fixed = true, fades = false },
})
light:via(COORD_BINDING)

--------------------------------------------------------------------------------
-- State from the coordinator
--------------------------------------------------------------------------------

--- A state the coordinator pushed.
local function applyState(tParams)
  local state = DeserializeSafe(Select(tParams, "state"))
  if type(state) ~= "table" then
    return
  end
  if state.online == false then
    light:lost()
    UpdateProperty("Driver Status", "Device offline")
    return
  end
  light:declare(DECLARATION)
  local report = { on = state.on == true, level = (tonumber(state.brightnessPct) or 0) / 100 }
  -- An off light reports black, so only a lit one says its color.
  if state.on == true then
    local x, y = C4:ColorRGBtoXY(channel(state.red or 255), channel(state.green or 255), channel(state.blue or 255))
    report.color = { x = x, y = y }
  end
  local verdict = light:report(report)
  -- Lit by another hand, the light has had its next on. A lit report from before the Off is history
  -- and keeps the color held.
  local kind = verdict and verdict.level and verdict.level.kind
  if state.on == true and (kind == "hand" or kind == "first") then
    heldColor = nil
  end
  UpdateProperty("Driver Status", "Connected")
end

--- The coordinator's side of the binding: the light's state, or its link to Hatch lost.
RFP[COORD_BINDING] = function(_idBinding, strCommand, tParams)
  if strCommand == "UPDATE_STATE" then
    applyState(tParams)
  elseif strCommand == "UPDATE_DISCONNECT" then
    light:lost({ suspended = toboolean(Select(tParams, "suspended")) })
    UpdateProperty("Driver Status", "Coordinator offline")
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
  light:start()
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

function OnDriverDestroyed()
  light:destroy()
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

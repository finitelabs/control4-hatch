-- Hatch Night Light companion.
--
-- Presents one Hatch device's RGB night light as a Control4 light_v2 proxy.
-- Owns no cloud connection: it binds to the Hatch account coordinator
-- (HATCH_LIGHT), receives its on/color/brightness as UPDATE_STATE, and sends
-- on/off/color/brightness actions to the coordinator as ENTITY_COMMAND.
--
-- Color crosses the boundary as RGB (0-255); the light_v2 proxy speaks CIE xy.
-- We use Control4's built-in converters (C4:ColorRGBtoXY / C4:ColorXYtoRGB) so
-- there is no hand-rolled color math here. Brightness is a 0-100 percentage on
-- both sides, so it passes through unscaled.

--#ifdef DRIVERCENTRAL
require("cloud-client-byte")
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")

local PROXY_BINDING = 5001
local COORD_BINDING = 5002

-- light_v2 color modes: 0 = full color (xy), 1 = correlated color temperature.
-- The Hatch night light is RGB only, so we always report full color.
local LIGHT_COLOR_MODE_FULL = 0

gInitialized = false

-- Last state the coordinator pushed, kept so TOGGLE and ON can reason about
-- whether the light is currently on and what color to restore.
local lightState = {
  online = true,
  on = false,
  red = 255,
  green = 255,
  blue = 255,
  brightnessPct = 100,
}

--------------------------------------------------------------------------------
-- Coordinator link
--------------------------------------------------------------------------------

--- Send an action to the coordinator, which maps it to a device shadow update.
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

local function notifyColor(red, green, blue)
  local x, y = C4:ColorRGBtoXY(tonumber(red) or 255, tonumber(green) or 255, tonumber(blue) or 255)
  if not (x and y) then
    return
  end
  SendToProxy(PROXY_BINDING, "LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = x,
    LIGHT_COLOR_CURRENT_Y = y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = LIGHT_COLOR_MODE_FULL,
  }, "NOTIFY")
end

--------------------------------------------------------------------------------
-- State from coordinator
--------------------------------------------------------------------------------

local function applyState(tParams)
  local state = DeserializeSafe(Select(tParams, "state"))
  if type(state) ~= "table" then
    return
  end
  lightState.online = state.online ~= false
  lightState.on = state.on == true
  lightState.red = tonumber(state.red) or lightState.red
  lightState.green = tonumber(state.green) or lightState.green
  lightState.blue = tonumber(state.blue) or lightState.blue
  lightState.brightnessPct = tonumber(state.brightnessPct) or lightState.brightnessPct

  -- When off, the proxy expects brightness 0; the last color is retained so the
  -- color chip in Navigator stays meaningful.
  notifyBrightness(lightState.on and lightState.brightnessPct or 0)
  notifyColor(lightState.red, lightState.green, lightState.blue)
  UpdateProperty("Driver Status", lightState.online and "Connected" or "Device offline")
end

--------------------------------------------------------------------------------
-- Proxy command handlers (light_v2 -> coordinator)
--------------------------------------------------------------------------------

function RFP.ON(idBinding)
  if idBinding ~= PROXY_BINDING then
    return
  end
  entityCommand({ command = "on" })
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
  entityCommand({ command = lightState.on and "off" or "on" })
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
  entityCommand({ command = "setBrightness", brightness = pct })
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

function RFP.SET_COLOR_TARGET(idBinding, _strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local x = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_X"))
  local y = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_Y"))
  if not (x and y) then
    log:warn("SET_COLOR_TARGET without xy coordinates ignored")
    return
  end
  local red, green, blue = C4:ColorXYtoRGB(x, y)
  if not (red and green and blue) then
    return
  end
  local function clamp(v)
    v = math.floor((tonumber(v) or 0) + 0.5)
    if v < 0 then
      return 0
    elseif v > 255 then
      return 255
    end
    return v
  end
  entityCommand({ command = "setColor", red = clamp(red), green = clamp(green), blue = clamp(blue) })
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

  local handler = RFP[strCommand]
  if type(handler) == "function" then
    local ok, err = pcall(handler, idBinding, strCommand, tParams)
    if not ok then
      log:warn("Hatch light command '%s' error: %s", strCommand, tostring(err))
    end
  end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
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
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end
  gInitialized = true
  UpdateProperty("Driver Status", "Ready")
  -- Ask the coordinator to push our current state.
  SendToProxy(COORD_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end

function OPC.Log_Mode(v)
  log:setLogMode(v)
end

function OPC.Log_Level(v)
  log:setLogLevel(v)
end

function OPC.Driver_Status(_v) end

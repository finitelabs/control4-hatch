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

local PROXY_BINDING = 5001
local COORD_BINDING = 5002

-- light_v2 color modes: 0 = full color (xy), 1 = correlated color temperature.
-- The Hatch night light is RGB only, so we always report full color.
local LIGHT_COLOR_MODE_FULL = 0

gInitialized = false

-- Last state the coordinator pushed, kept so TOGGLE and ON can reason about
-- whether the light is currently on and what color to restore.
local lightState = {
  -- Pessimistic until the coordinator hands the device over: reporting a load
  -- as reachable before then makes Navigator accept commands that go nowhere.
  online = false,
  on = false,
  red = 255,
  green = 255,
  blue = 255,
  brightnessPct = 100,
}

-- A color Control4 set while the light was off { x, y, red, green, blue, preset }: the night light cannot take a color
-- without lighting, so it is kept, and the next on comes on in it. Cleared once the light is on.
local nextOnColor = nil
-- An on was sent and the light has not yet reported it: a color sent now is for the light on its way on.
local onSent = false
-- An off was sent and the light has not reported since: a color sent now would light it again, so it is kept.
local offSent = false
-- The color preset { id, origin, red, green, blue } the light was last sent: told with its color while a report shows
-- that color.
local colorPreset = nil
-- The brightness preset the last SET_BRIGHTNESS_TARGET named, told with the level; any other level command clears it.
local brightnessPresetId = nil
-- Until when a Navigator On's follow-up is expected, after an on that came on in nextOnColor: the proxy sends the
-- Color On Mode's own color, naming its preset, 5-6 ms after the level (dev, 2026-11-08).
local heldOnFollowUpUntil = nil
-- The last turn-on carried nextOnColor, for its command to arm heldOnFollowUpUntil.
local heldOnSent = false

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
    LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = brightnessPresetId,
  }, "NOTIFY")
end

--- Tell the proxy the load is reachable. Without it Navigator grays the light
--- out however correct its brightness and color reports are.
local function notifyOnline(online)
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = online and true or false }, "NOTIFY")
end

--- @param preset table|nil The color preset { id, origin } the color is, which the proxy names it by.
local function notifyXY(x, y, preset)
  SendToProxy(PROXY_BINDING, "LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = x,
    LIGHT_COLOR_CURRENT_Y = y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = LIGHT_COLOR_MODE_FULL,
    LIGHT_COLOR_CURRENT_PRESET_ID = preset and preset.id,
    LIGHT_COLOR_CURRENT_PRESET_ORIGIN = preset and preset.origin,
  }, "NOTIFY")
end

local function notifyColor(red, green, blue, preset)
  local x, y = C4:ColorRGBtoXY(tonumber(red) or 255, tonumber(green) or 255, tonumber(blue) or 255)
  if x and y then
    notifyXY(x, y, preset)
  end
end

--- Forget the device the light was bound to: the one it is bound to next tells its own state.
local function forgetDevice()
  lightState.online, lightState.on = false, false
  lightState.red, lightState.green, lightState.blue, lightState.brightnessPct = 255, 255, 255, 100
  nextOnColor, onSent, offSent, heldOnFollowUpUntil, heldOnSent = nil, false, false, nil, false
  colorPreset, brightnessPresetId = nil, nil
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
  offSent = false
  if lightState.on then
    nextOnColor = nil
    onSent = false
  end
  -- An off light reports no color, so only a lit one says whether it still shows the preset's.
  local shown = colorPreset
  if
    lightState.on
    and not (
      shown
      and lightState.red == shown.red
      and lightState.green == shown.green
      and lightState.blue == shown.blue
    )
  then
    colorPreset = nil
  end

  notifyOnline(lightState.online)
  -- When off, the proxy expects brightness 0; the last color is retained so the
  -- color chip in Navigator stays meaningful.
  notifyBrightness(lightState.on and lightState.brightnessPct or 0)
  if nextOnColor then
    notifyXY(nextOnColor.x, nextOnColor.y, nextOnColor.preset)
  else
    notifyColor(lightState.red, lightState.green, lightState.blue, colorPreset)
  end
  UpdateProperty("Driver Status", lightState.online and "Connected" or "Device offline")
end

--------------------------------------------------------------------------------
-- Proxy command handlers (light_v2 -> coordinator)
--------------------------------------------------------------------------------

--- Send a command that turns the light on, with the color set while it was off.
local function turnOn(body)
  if nextOnColor then
    body.red, body.green, body.blue = nextOnColor.red, nextOnColor.green, nextOnColor.blue
    local preset = nextOnColor.preset
    colorPreset = preset
      and { id = preset.id, origin = preset.origin, red = body.red, green = body.green, blue = body.blue }
    heldOnSent = true
  end
  -- An On the account cannot send never reaches the light.
  onSent = onSent or (lightState.online and not lightState.on)
  offSent = false
  entityCommand(body)
end

--- Send a command that turns the light off.
local function turnOff(body)
  onSent = false
  -- An Off the account cannot send never reaches the light either.
  offSent = lightState.online
  entityCommand(body)
end

function RFP.ON(idBinding)
  if idBinding ~= PROXY_BINDING then
    return
  end
  brightnessPresetId = nil
  turnOn({ command = "on" })
end

function RFP.OFF(idBinding)
  if idBinding ~= PROXY_BINDING then
    return
  end
  brightnessPresetId = nil
  turnOff({ command = "off" })
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
  brightnessPresetId = nil
  if lightState.on then
    turnOff({ command = "off" })
  else
    turnOn({ command = "on" })
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
  if pct > 0 then
    turnOn({ command = "setBrightness", brightness = pct })
  else
    turnOff({ command = "setBrightness", brightness = pct })
  end
end

function RFP.GET_CONNECTED_STATE(idBinding)
  if idBinding ~= PROXY_BINDING then
    return
  end
  notifyOnline(lightState.online)
end

function RFP.SET_LEVEL(idBinding, _strCommand, tParams)
  brightnessPresetId = nil
  setBrightness(idBinding, Select(tParams, "LEVEL"))
end

function RFP.SET_BRIGHTNESS_TARGET(idBinding, _strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  brightnessPresetId = tointeger(Select(tParams, "LIGHT_BRIGHTNESS_TARGET_PRESET_ID"))
  heldOnSent = false
  setBrightness(idBinding, Select(tParams, "LIGHT_BRIGHTNESS_TARGET"))
  -- A Navigator On arrives as a level naming a brightness preset, and its follow-up color comes next. Programming's
  -- On, Toggle or a plain level sends none.
  if heldOnSent and Select(tParams, "LIGHT_BRIGHTNESS_TARGET_PRESET_ID") then
    heldOnFollowUpUntil = C4:GetTime() + 250
  end
  heldOnSent = false
end

function RFP.RAMP_TO_LEVEL(idBinding, _strCommand, tParams)
  brightnessPresetId = nil
  setBrightness(idBinding, Select(tParams, "LEVEL"))
end

function RFP.SET_COLOR_TARGET(idBinding, _strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  -- The driver takes no Color On Mode, so a color naming any preset in the window is the Navigator On's own.
  local followUpUntil = heldOnFollowUpUntil
  heldOnFollowUpUntil = nil
  local named = Select(tParams, "LIGHT_COLOR_TARGET_PRESET_ID") and Select(tParams, "LIGHT_COLOR_TARGET_PRESET_ORIGIN")
  if followUpUntil and C4:GetTime() < followUpUntil and named and nextOnColor then
    log:debug("SET_COLOR_TARGET of a preset after an on in a color set while off: not applied")
    notifyXY(nextOnColor.x, nextOnColor.y, nextOnColor.preset)
    return
  end
  local presetId = tointeger(Select(tParams, "LIGHT_COLOR_TARGET_PRESET_ID"))
  local presetOrigin = tointeger(Select(tParams, "LIGHT_COLOR_TARGET_PRESET_ORIGIN"))
  local preset = presetId and presetOrigin and { id = presetId, origin = presetOrigin } or nil
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
  -- Off, or with an off on its way, the color waits for the next on, which would otherwise light it now.
  if offSent or not (lightState.on or onSent) then
    nextOnColor = { x = x, y = y, red = clamp(red), green = clamp(green), blue = clamp(blue), preset = preset }
    notifyXY(x, y, preset)
    return
  end
  colorPreset = preset
    and { id = preset.id, origin = preset.origin, red = clamp(red), green = clamp(green), blue = clamp(blue) }
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
      lightState.online = false
      onSent, offSent = false, false
      notifyOnline(false)
      -- A lost link to Hatch reads off. The account's own stop leaves the light as it was, and its next report tells it.
      if not toboolean(Select(tParams, "suspended")) then
        lightState.on = false
        brightnessPresetId = nil
        notifyBrightness(0)
      end
      UpdateProperty("Driver Status", "Coordinator offline")
    end
    return
  end

  local handler = RFP[strCommand]
  if type(handler) == "function" then
    local ok, err = pcall(handler, idBinding, strCommand, tParams)
    if not ok then
      log:warn("Hatch light command '%s' error: %s", strCommand, tostring(err))
      --#ifdef DRIVERCENTRAL
      diagnostics:captureError(tostring(err), nil, "RFP." .. strCommand)
      --#endif
    end
  end
end

--#ifdef DRIVERCENTRAL
-- The vendored dispatcher this replaces is what reports a proxy command's error.
ReceivedFromProxy = diagnostics:wrap(ReceivedFromProxy, "ReceivedFromProxy")
--#endif

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
  -- Declare offline before asking for state, so nothing reads the proxy as
  -- reachable in the window before the coordinator answers.
  notifyOnline(false)
  SendToProxy(COORD_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

--- Announce reachability on bind and retract it on unbind, per light_v2.
OBC = OBC or {}
OBC[COORD_BINDING] = function(_idBinding, _strClass, bIsBound)
  forgetDevice()
  -- At a controller start this runs before late init, which tells offline itself.
  if gInitialized then
    notifyOnline(false)
  end
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

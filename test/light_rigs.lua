-- The Hatch lights' rigs for the adapter contract (test/test_light_contract.lua). Each loads the
-- driver as it ships and fakes only the account coordinator on binding 5002: it takes the driver's
-- ENTITY_COMMANDs as drivers/hatch/driver.lua maps them onto the device, and pushes UPDATE_STATE a
-- moment later, as the cloud does.

local D = require("light_drivers")
local F = require("c4_fixtures")
local H = require("light_harness")
local Light = require("lib.light")

local COORD = 5002
-- How long the cloud takes to push the state a command left.
local LATENCY_MS = 300

-- Control4's RGB converters, which the shim leaves out, through the library's own helpers.
function C4:ColorXYtoRGB(x, y)
  local r, g, b = Light.color.xyToRGB(x, y)
  return r * 255, g * 255, b * 255
end
function C4:ColorRGBtoXY(red, green, blue)
  return Light.color.rgbToXY(red / 255, green / 255, blue / 255)
end

-- The shim answers no driver.xml section but connections, and late init reads the minimum OS.
local config = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return config(self, section)
end

--- A local the function closes over, by name.
local function upvalue(fn, name)
  for i = 1, math.huge do
    local key, value = debug.getupvalue(fn, i)
    if key == nil then
      return nil
    elseif key == name then
      return value
    end
  end
end

--- The night light, as the coordinator drives it.
local function lightCommand(shadow, body)
  local red = tonumber(body.red) or shadow.red
  local green = tonumber(body.green) or shadow.green
  local blue = tonumber(body.blue) or shadow.blue
  local function lit(brightness)
    if not brightness or brightness <= 0 then
      brightness = shadow.brightnessPct > 0 and shadow.brightnessPct or 100
    end
    shadow.on, shadow.red, shadow.green, shadow.blue, shadow.brightnessPct = true, red, green, blue, brightness
  end
  if body.command == "on" or body.command == "setColor" then
    lit(tonumber(body.brightness))
  elseif body.command == "off" then
    shadow.on = false
  elseif body.command == "setBrightness" then
    local brightness = tonumber(body.brightness) or 0
    if brightness <= 0 then
      shadow.on = false
    else
      lit(brightness)
    end
  end
end

--- The sound machine's volume, as the coordinator drives it: a level never starts playback.
local function volumeCommand(shadow, body)
  if body.command == "on" then
    shadow.on = true
    shadow.brightnessPct = tonumber(body.brightness) or shadow.brightnessPct
  elseif body.command == "off" then
    shadow.on = false
  elseif body.command == "setBrightness" then
    shadow.brightnessPct = tonumber(body.brightness) or shadow.brightnessPct
  end
end

--- A rig for one of the two drivers.
--- @param folder string
--- @param color boolean Whether the device has color.
--- @param command function How the coordinator applies an ENTITY_COMMAND to the shadow.
local function rig(folder, color, command)
  local path = D.root() .. "/drivers/" .. folder .. "/driver.lua"
  local r = { name = folder, links = color }

  function r.load(h)
    local shadow = { online = true, on = false, red = 255, green = 255, blue = 255, brightnessPct = 40 }
    local function push()
      local state = {}
      for k, v in pairs(shadow) do
        state[k] = v
      end
      ReceivedFromProxy(COORD, "UPDATE_STATE", { state = SerializeSafe(state) })
    end
    local prior = C4.SendToProxy
    C4.SendToProxy = function(self, id, cmd, params, ...)
      if id == COORD then
        if cmd == "ENTITY_COMMAND" then
          command(shadow, DeserializeSafe(params.body))
          h.clock.at(LATENCY_MS, push)
        elseif cmd == "REFRESH_STATE" then
          h.clock.at(LATENCY_MS, push)
        end
        return
      end
      return prior(self, id, cmd, params, ...)
    end
    Properties["Driver Status"] = ""
    F.dofileBuild(path, "oss")
    h.light = Light.made[#Light.made]
    OnDriverInit()
    OnDriverLateInit()
    local declaration = upvalue(upvalue(RFP[COORD], "applyState"), "DECLARATION")
    return {
      state = function()
        local state = { on = shadow.on, level = shadow.brightnessPct / 100 }
        if color then
          local x, y = C4:ColorRGBtoXY(shadow.red, shadow.green, shadow.blue)
          state.color = { x = x, y = y }
        end
        return state
      end,
      set = function(state, _, quiet)
        if state.on ~= nil then
          shadow.on = state.on
        end
        if state.level then
          shadow.brightnessPct = math.floor(state.level * 100 + 0.5)
        end
        if state.color and state.color.x then
          local red, green, blue = C4:ColorXYtoRGB(state.color.x, state.color.y)
          shadow.red, shadow.green, shadow.blue = math.floor(red + 0.5), math.floor(green + 0.5), math.floor(blue + 0.5)
        end
        if not quiet then
          push()
        end
      end,
      drop = function()
        shadow.online = false
        push()
      end,
      back = function()
        shadow.online = true
        push()
      end,
      dims = true,
      color = color,
      stops = false,
      declaration = function()
        return declaration
      end,
    }
  end

  F.dofileBuild(path, "oss")
  r.declarations = { upvalue(upvalue(RFP[COORD], "applyState"), "DECLARATION") }
  return r
end

return {
  version = H.RIG_VERSION,
  rigs = {
    hatch_light = { rig("hatch_light", true, lightCommand) },
    hatch_volume = { rig("hatch_volume", false, volumeCommand) },
  },
}

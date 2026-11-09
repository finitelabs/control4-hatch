-- The Hatch Night Light and a color set while it is off. The night light cannot take a color without lighting, so the
-- driver keeps it: it is told at once, the next on or level comes on in it, and it is dropped once the light reports
-- it is on.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_hatch_light.lua

require("c4_shim")
require("c4_local")
local T = require("testlib")

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
local PROXY, COORD = 5001, 5002

-- A pair of converters that undo each other, standing in for Control4's.
function C4:ColorXYtoRGB(x, y)
  return x * 255, y * 255, 0
end
function C4:ColorRGBtoXY(red, green)
  return red / 255, green / 255
end
local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  return section == "minimum_os_version" and "3.3.0" or configInfo(self, section)
end

-- A clock the test moves.
local clock = 0
function C4:GetTime()
  return clock
end

local told = {}
function C4:SendToProxy(id, command, params)
  told[#told + 1] = { id = id, command = command, params = params or {} }
end

Properties["Driver Status"] = ""
ShimDofileBuild(HERE .. "../drivers/hatch_light/driver.lua", "oss")
OnDriverInit()
OnDriverLateInit()

local function mark()
  told = {}
end

--- The commands sent to the Hatch driver since the mark.
local function sent()
  local out = {}
  for _, t in ipairs(told) do
    if t.id == COORD and t.command == "ENTITY_COMMAND" then
      out[#out + 1] = DeserializeSafe(t.params.body)
    end
  end
  return out
end

--- The x of each color told to the proxy since the mark.
local function colorsTold()
  local out = {}
  for _, t in ipairs(told) do
    if t.id == PROXY and t.command == "LIGHT_COLOR_CHANGED" then
      out[#out + 1] = t.params.LIGHT_COLOR_CURRENT_X
    end
  end
  return out
end

local function proxy(command, params)
  ReceivedFromProxy(PROXY, command, params or {})
end

--- The Hatch driver's state for the light: on in the color given, or off and dark.
local function report(on, rgb)
  rgb = rgb or { 0, 0, 0 }
  ReceivedFromProxy(COORD, "UPDATE_STATE", {
    state = SerializeSafe({
      online = true,
      on = on,
      red = rgb[1],
      green = rgb[2],
      blue = rgb[3],
      brightnessPct = on and 100 or 0,
    }),
  })
end

local GREEN = { LIGHT_COLOR_TARGET_X = 0.2, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_MODE = 0 }
local GREEN_SENT = { red = 51, green = 153, blue = 0 }

--- The red, green and blue a command carries, nil for none.
local function colorOf(cmd)
  return cmd and cmd.red and { red = cmd.red, green = cmd.green, blue = cmd.blue } or nil
end

T.section("a color set while the light is off is kept for its next on, and told at once")
report(false)
mark()
proxy("SET_COLOR_TARGET", GREEN)
T.eq("nothing is sent, so the light stays off", sent(), {})
T.eq("the proxy is told it at once", colorsTold(), { 0.2 })
mark()
report(false)
T.eq("a report while still off tells the kept color, not the dark one", colorsTold(), { 0.2 })
mark()
proxy("ON")
T.eq("the next on comes on in it, in one command", sent(), { { command = "on", red = 51, green = 153, blue = 0 } })
report(true, { 51, 153, 0 })
proxy("OFF")
report(false)
mark()
proxy("ON")
T.eq("once the light has reported on, the next on carries no kept color", colorOf(sent()[1]), nil)
report(true, { 51, 153, 0 })

T.section("a level or Toggle from off comes on in it too")
proxy("OFF")
report(false)
proxy("SET_COLOR_TARGET", GREEN)
mark()
proxy("SET_LEVEL", { LEVEL = 40 })
T.eq(
  "a level carries it with the level",
  sent(),
  { { command = "setBrightness", brightness = 40, red = 51, green = 153, blue = 0 } }
)
report(true, { 51, 153, 0 })
proxy("OFF")
report(false)
proxy("SET_COLOR_TARGET", GREEN)
mark()
proxy("TOGGLE")
T.eq("Toggle from off carries it", colorOf(sent()[1]), GREEN_SENT)
report(true, { 51, 153, 0 })
mark()
proxy("SET_LEVEL", { LEVEL = 0 })
T.eq("a level of 0 is still an off", sent(), { { command = "setBrightness", brightness = 0 } })
report(false)

T.section("a color for a light that is on, or on its way on, goes out at once")
mark()
proxy("ON")
proxy("SET_COLOR_TARGET", GREEN)
T.eq(
  "On, then a color before the light reports on: both go out",
  sent(),
  { { command = "on" }, { command = "setColor", red = 51, green = 153, blue = 0 } }
)
report(true, { 51, 153, 0 })
mark()
proxy("SET_COLOR_TARGET", GREEN)
T.eq("on: a color goes out", sent(), { { command = "setColor", red = 51, green = 153, blue = 0 } })

T.section("turned on elsewhere, the light has had its next on")
proxy("OFF")
report(false)
proxy("SET_COLOR_TARGET", GREEN)
report(true, { 255, 255, 255 })
report(false)
mark()
proxy("ON")
T.eq("the on after it carries no kept color", colorOf(sent()[1]), nil)

T.section("an On that cannot reach the light leaves a color set while off kept")
proxy("OFF")
report(false)
proxy("ON")
ReceivedFromProxy(COORD, "UPDATE_DISCONNECT", {})
report(false)
mark()
proxy("SET_COLOR_TARGET", GREEN)
T.eq("an On, then the account disconnected: the color is kept, not sent", sent(), {})
ReceivedFromProxy(COORD, "UPDATE_DISCONNECT", {})
proxy("ON")
mark()
proxy("SET_COLOR_TARGET", GREEN)
T.eq("an On while disconnected: the color is kept, not sent", sent(), {})

T.section("a Navigator On's own color, sent right after its level, leaves the color set while off")
-- A Navigator On: its level, then 5 ms later the Color On Mode's own color, naming its preset (dev, 2026-11-08).
local WHITE_PRESET = {
  LIGHT_COLOR_TARGET_X = 0.42,
  LIGHT_COLOR_TARGET_Y = 0.4,
  LIGHT_COLOR_TARGET_MODE = 0,
  LIGHT_COLOR_TARGET_COLOR_RATE = 750,
  LIGHT_COLOR_TARGET_PRESET_ID = 1,
  LIGHT_COLOR_TARGET_PRESET_ORIGIN = 1,
}
local function levelOn()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750, LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 })
end
report(false)
proxy("SET_COLOR_TARGET", GREEN)
mark()
levelOn()
clock = clock + 5
proxy("SET_COLOR_TARGET", WHITE_PRESET)
T.eq(
  "its level carries the color set while off, and its own color is not sent",
  sent(),
  { { command = "setBrightness", brightness = 100, red = 51, green = 153, blue = 0 } }
)
T.eq("the proxy is told the color the light keeps", colorsTold(), { 0.2 })
report(true, { 51, 153, 0 })
proxy("OFF")
report(false)
proxy("SET_COLOR_TARGET", GREEN)
levelOn()
clock = clock + 5
mark()
proxy("SET_COLOR_TARGET", GREEN)
T.eq("a color naming no preset right after the level is a new pick", #sent(), 1)
report(true, { 51, 153, 0 })
proxy("OFF")
report(false)
proxy("SET_COLOR_TARGET", GREEN)
levelOn()
clock = clock + 300
mark()
proxy("SET_COLOR_TARGET", WHITE_PRESET)
T.eq("a preset's color well after the level is a pick too", #sent(), 1)

T.finish()

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

-- This is the released Night Light's suite, run once against the light library. Each of its assertions the library
-- answers differently is marked with T.differs, under the row that says why, and followed by what the light does now.

-- The library's rows for every released light driver, as the light library words them.
local R_SHOWN = "A command for the level or color the proxy shows tells nothing."
local R_REBIND = "A rebind to another device shows the light offline until the new device reports."
-- Hatch's own rows: the design's section 6 for Hatch, and the Night Light's adapter.
local R_SEND = "hatch: Control4 is told a change as the command goes out"
local R_WIRE = "hatch: every lit Night Light command carries its color and brightness, and a level of 0 is an Off"
-- Differences no integrator sees.
local BENIGN = {
  RETELL = "benign: a color the proxy already shows is told again or not",
}

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
local PROXY, COORD = 5001, 5002

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
-- The green on the wire: its channels at full intensity, as the adapter converts it.
local GREEN_SENT = {}
do
  local r, g, b = require("lib.light.color").xyToRGB(0.2, 0.6)
  GREEN_SENT = { red = round(r * 255), green = round(g * 255), blue = round(b * 255) }
end
local GREEN_RGB = { GREEN_SENT.red, GREEN_SENT.green, GREEN_SENT.blue }

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
T.differs("a report while still off tells the kept color, not the dark one", BENIGN.RETELL)
T.eq("a report while still off leaves the kept color, not the dark one", colorsTold(), {})
mark()
proxy("ON")
T.differs("the next on comes on in it, in one command", R_WIRE)
T.eq(
  "the next on comes on in it, in one command",
  sent(),
  { { command = "on", red = GREEN_SENT.red, green = GREEN_SENT.green, blue = GREEN_SENT.blue, brightness = 100 } }
)
report(true, GREEN_RGB)
proxy("OFF")
report(false)
mark()
proxy("ON")
T.differs("once the light has reported on, the next on carries no kept color", R_WIRE)
T.eq("once the light has reported on, the next on comes on in the light's own color", colorOf(sent()[1]), GREEN_SENT)
report(true, GREEN_RGB)

T.section("a level or Toggle from off comes on in it too")
proxy("OFF")
report(false)
proxy("SET_COLOR_TARGET", GREEN)
mark()
proxy("SET_LEVEL", { LEVEL = 40 })
T.differs("a level carries it with the level", R_WIRE)
T.eq(
  "a level carries it with the level",
  sent(),
  { { command = "on", red = GREEN_SENT.red, green = GREEN_SENT.green, blue = GREEN_SENT.blue, brightness = 40 } }
)
report(true, GREEN_RGB)
proxy("OFF")
report(false)
proxy("SET_COLOR_TARGET", GREEN)
mark()
proxy("TOGGLE")
T.eq("Toggle from off carries it", colorOf(sent()[1]), GREEN_SENT)
report(true, GREEN_RGB)
mark()
proxy("SET_LEVEL", { LEVEL = 0 })
T.differs("a level of 0 is still an off", R_WIRE)
T.eq("a level of 0 is still an off", sent(), { { command = "off" } })
report(false)

T.section("a color for a light that is on, or on its way on, goes out at once")
mark()
proxy("ON")
proxy("SET_COLOR_TARGET", GREEN)
T.differs("On, then a color before the light reports on: both go out", R_WIRE)
T.eq(
  "On, then the same color before the light reports on: both go out, each with its color and brightness",
  sent(),
  {
    { command = "on", red = GREEN_SENT.red, green = GREEN_SENT.green, blue = GREEN_SENT.blue, brightness = 100 },
    { command = "setColor", red = GREEN_SENT.red, green = GREEN_SENT.green, blue = GREEN_SENT.blue, brightness = 100 },
  }
)
report(true, GREEN_RGB)
mark()
proxy("SET_COLOR_TARGET", GREEN)
T.differs("on: a color goes out", R_WIRE)
T.eq("on: the color it shows goes out again, with its brightness", sent(), {
  { command = "setColor", red = GREEN_SENT.red, green = GREEN_SENT.green, blue = GREEN_SENT.blue, brightness = 100 },
})

T.section("turned on elsewhere, the light has had its next on")
proxy("OFF")
report(false)
proxy("SET_COLOR_TARGET", GREEN)
report(true, { 255, 255, 255 })
report(false)
mark()
proxy("ON")
T.differs("the on after it carries no kept color", R_WIRE)
T.eq("the on after it comes on in the light's own color", colorOf(sent()[1]), { red = 255, green = 255, blue = 255 })

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
T.differs("its level carries the color set while off, and its own color is not sent", R_WIRE)
T.eq(
  "its level carries the color set while off, and its own color is not sent",
  sent(),
  { { command = "on", red = GREEN_SENT.red, green = GREEN_SENT.green, blue = GREEN_SENT.blue, brightness = 100 } }
)
T.eq("the proxy is told the color the light keeps", colorsTold(), { 0.2 })
report(true, GREEN_RGB)
proxy("OFF")
report(false)
proxy("SET_COLOR_TARGET", GREEN)
levelOn()
clock = clock + 5
mark()
proxy("SET_COLOR_TARGET", GREEN)
T.eq("a color naming no preset right after the level is a new pick", #sent(), 1)
report(true, GREEN_RGB)
proxy("OFF")
report(false)
proxy("SET_COLOR_TARGET", GREEN)
levelOn()
clock = clock + 300
mark()
proxy("SET_COLOR_TARGET", WHITE_PRESET)
T.eq("a preset's color well after the level is a pick too", #sent(), 1)
-- Programming's On, Toggle and a level naming no brightness preset send no follow-up: a preset's color right after
-- one is a command.
for _, on in ipairs({
  {
    "programming's On",
    function()
      proxy("ON")
    end,
  },
  {
    "Toggle",
    function()
      proxy("TOGGLE")
    end,
  },
  {
    "a level naming no brightness preset",
    function()
      proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
    end,
  },
}) do
  report(true, GREEN_RGB)
  proxy("OFF")
  report(false)
  proxy("SET_COLOR_TARGET", GREEN)
  on[2]()
  clock = clock + 5
  mark()
  proxy("SET_COLOR_TARGET", WHITE_PRESET)
  T.eq(on[1] .. ", then a preset's color: it goes out", #sent(), 1)
end

--- What the proxy was told since the mark, in order, as "online=<state>", "level=<n>[/<preset>]" and
--- "color=<x>[/<id>.<origin>]".
local function toldInOrder()
  local out = {}
  for _, t in ipairs(told) do
    local p = t.params
    if t.id == PROXY and t.command == "ONLINE_CHANGED" then
      out[#out + 1] = "online=" .. tostring(p.STATE)
    elseif t.id == PROXY and t.command == "LIGHT_BRIGHTNESS_CHANGED" then
      out[#out + 1] = "level="
        .. tostring(p.LIGHT_BRIGHTNESS_CURRENT)
        .. (p.LIGHT_BRIGHTNESS_CURRENT_PRESET_ID and ("/" .. p.LIGHT_BRIGHTNESS_CURRENT_PRESET_ID) or "")
    elseif t.id == PROXY and t.command == "LIGHT_COLOR_CHANGED" then
      out[#out + 1] = "color="
        .. tostring(p.LIGHT_COLOR_CURRENT_X)
        .. (
          p.LIGHT_COLOR_CURRENT_PRESET_ID
            and ("/" .. p.LIGHT_COLOR_CURRENT_PRESET_ID .. "." .. p.LIGHT_COLOR_CURRENT_PRESET_ORIGIN)
          or ""
        )
    end
  end
  return out
end
local GREEN_PRESET = {
  LIGHT_COLOR_TARGET_X = 0.2,
  LIGHT_COLOR_TARGET_Y = 0.6,
  LIGHT_COLOR_TARGET_MODE = 0,
  LIGHT_COLOR_TARGET_PRESET_ID = 5,
  LIGHT_COLOR_TARGET_PRESET_ORIGIN = 2,
}

T.section("a color right after an Off, before the light reports off, waits for the next on")
report(true, GREEN_RGB)
mark()
proxy("OFF")
proxy("SET_COLOR_TARGET", GREEN)
T.eq("the Off goes out and the color is kept, not sent", sent(), { { command = "off" } })
report(false)
mark()
proxy("ON")
T.eq("the next on comes on in it", colorOf(sent()[1]), GREEN_SENT)
report(true, GREEN_RGB)
mark()
proxy("SET_LEVEL", { LEVEL = 0 })
proxy("SET_COLOR_TARGET", GREEN)
T.differs("a level of 0, then a color: the same", R_WIRE)
T.eq("a level of 0, then a color: the same", sent(), { { command = "off" } })
report(false)

T.section("a preset's color is told with its id and origin while the light shows it")
mark()
proxy("SET_COLOR_TARGET", GREEN_PRESET)
T.eq("set while off: told at once in its preset", toldInOrder(), { "color=0.2/5.2" })
mark()
proxy("ON")
report(true, GREEN_RGB)
T.differs("and once the light shows it", R_SEND)
T.eq("the On tells its level, the preset's color told already", toldInOrder(), { "level=100" })
mark()
proxy("SET_COLOR_TARGET", GREEN_PRESET)
report(true, GREEN_RGB)
T.differs("set while on: told in its preset once the light shows it", R_SHOWN)
T.eq("set while on in the preset it shows: nothing to tell", toldInOrder(), {})
proxy("OFF")
report(false)
mark()
proxy("ON")
report(true, GREEN_RGB)
T.differs("off, then on again in the same color: still told in its preset", R_SEND)
T.eq("off, then on again in the same color: still told in its preset", toldInOrder(), { "color=0.2/5.2", "level=100" })
mark()
report(true, { 255, 0, 0 })
T.eq(
  "a report of another color names no preset",
  toldInOrder(),
  { "color=" .. tostring(round(require("lib.light.color").rgbToXY(1, 0, 0), 3)) }
)

T.section("a level's brightness preset is told with the level, until another level command")
mark()
proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 3 })
report(true, { 255, 0, 0 })
T.differs("a level naming a preset: told in it", R_SEND)
T.eq("a level naming a preset: told in it", toldInOrder(), { "level=60/3" })
mark()
proxy("SET_LEVEL", { LEVEL = 40 })
report(true, { 255, 0, 0 })
T.differs("a level naming none: told in none", R_SEND)
T.eq("a level naming none: told in none", toldInOrder(), { "level=40" })

T.section("a rebind forgets the device the light was bound to")
report(false)
proxy("SET_COLOR_TARGET", GREEN)
mark()
OBC[COORD](COORD, "HATCH_LIGHT", true)
T.eq("the proxy is told offline, not the old device's state", toldInOrder(), { "online=false" })
report(false)
mark()
proxy("ON")
T.differs("and a color set before the rebind is not the next on's", R_REBIND)
T.eq(
  "and a color set before the rebind is the one the proxy shows, which the next on carries",
  colorOf(sent()[1]),
  GREEN_SENT
)
report(true, { 255, 255, 255 })

T.section("a lost link to Hatch reads off; the account's own stop leaves the light as it was")
mark()
ReceivedFromProxy(COORD, "UPDATE_DISCONNECT", {})
T.eq("a lost link: offline, then off", toldInOrder(), { "online=false", "level=0" })
report(true, { 255, 255, 255 })
mark()
ReceivedFromProxy(COORD, "UPDATE_DISCONNECT", { suspended = true })
T.eq("the account's own stop: offline only", toldInOrder(), { "online=false" })

T.section("the build declares only what the night light does")
do
  local made = require("lib.light").made
  local caps = {}
  for _, row in ipairs(require("lib.light.caps").static(made[#made].profile)) do
    caps[row.key] = row.value
  end
  for _, name in ipairs({ "dimmer", "set_level", "supports_target", "on_off", "supports_color" }) do
    T.eq(name .. " is True", caps[name], "True")
  end
  for _, name in ipairs({
    "supports_default_on",
    "ramp_level",
    "advanced_scene_support",
    "reduced_als_support",
    "brightness_on_mode_preset",
    "brightness_on_mode_previous",
    "color_on_mode_fade",
    "color_on_mode_preset",
    "color_on_mode_previous",
    "supports_brightness_stop",
    "supports_color_stop",
    "click_rates",
    "hold_rates",
    "has_leds",
    "has_button_events",
  }) do
    T.eq(name .. " is False", caps[name], "False")
  end
end

T.finish()

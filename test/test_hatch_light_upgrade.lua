-- The v20261111 Night Light upgraded in place to the light library: over the proxy the release left, as a controller
-- holds it (hatch_v20261111_proxies.lua) and an empty store, the light reads the proxy's settings as they were. At
-- each start, a restart after the upgrade included, it tells its capabilities once and its level and color once, at
-- the values the proxy already shows, so nothing an integrator sees changes.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_hatch_light_upgrade.lua

require("c4_shim")
require("c4_local")
local T = require("testlib")
local F = require("c4_fixtures")
local Fake = require("light_proxy_fake")
local Color = require("lib.light.color")
local release = require("hatch_v20261111_proxies").nightLight

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
local COORD = 5002

local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  return section == "minimum_os_version" and "3.3.0" or configInfo(self, section)
end
Properties["Driver Status"] = ""

local clock = F.virtualClock()

--- Load the driver over a proxy holding `variables` and answering GET_SETUP with `setup`, start it, and have the
--- account tell it `state`.
--- @param variables table<integer, string>
--- @param state table
--- @param setup string|nil Default the release's.
--- @return FakeProxy proxy
--- @return Light light
local function upgrade(variables, state, setup)
  local proxy = Fake.install(clock, { setup = setup or release.setup, variables = variables, links = false })
  T.unload("^lib%.light", "^hatch%.")
  ShimDofileBuild(HERE .. "../drivers/hatch_light/driver.lua", "oss")
  OnDriverInit()
  OnDriverLateInit()
  ReceivedFromProxy(COORD, "UPDATE_STATE", { state = SerializeSafe(state) })
  clock.run(10000)
  local made = require("lib.light").made
  return proxy, made[#made]
end

--- What the upgraded light told the proxy that a release's proxy would show as a change.
--- @param proxy FakeProxy
--- @return table
local function changes(proxy)
  return {
    level = proxy:count("LIGHT_BRIGHTNESS_CHANGED") + proxy:count("LIGHT_BRIGHTNESS_CHANGING"),
    color = proxy:count("LIGHT_COLOR_CHANGED") + proxy:count("LIGHT_COLOR_CHANGING"),
  }
end

local OFF = { online = true, on = false, red = 0, green = 0, blue = 0, brightnessPct = 0 }

-- The release persists nothing, and the library's keys (lib.light.types) start empty.
local KEYS = {
  "preset_level",
  "click_rate_up",
  "click_rate_down",
  "hold_rate_up",
  "hold_rate_down",
  "brightness_rate_default",
  "color_rate_default",
  "brightness_on_mode",
  "button_colors",
  "brightness_presets",
  "color_presets",
  "color_on_mode",
  "previous_color",
  "brightness_on_mode_preset",
  "max_on_level",
  "min_on_level",
  "scenes",
  "light_rate_caps",
}
local function emptyStore()
  local persist = require("lib.persist")
  for _, key in ipairs(KEYS) do
    persist:delete(key)
  end
end

T.section("a night light left off")
emptyStore()
local proxy, light = upgrade(release.variables, OFF)
local s = light.settings
T.eq("Min and Max On as the proxy held them", { s:onRange() }, { 1, 100 })
T.eq("the Default On level", s:presetLevel(), 100)
T.eq("the default rates", { s:defaultRate(), s:defaultColorRate() }, { 750, 750 })
T.eq("the click and hold rates", { s:clickRate(true), s:clickRate(false), s:holdRate(true), s:holdRate(false) }, {
  250,
  750,
  5000,
  5000,
})
T.eq("the start tells the level once, at the 0 the proxy shows", { changes(proxy).level, proxy.level }, { 1, 0 })
T.eq("and no color, as the light is off", changes(proxy).color, 0)
T.eq("and its capabilities once", proxy:count("DYNAMIC_CAPABILITIES_CHANGED"), 1)
T.eq("and online", proxy.online, true)

T.section("then a Director restart")
local vars = {}
for id, v in pairs(proxy.vars) do
  vars[tonumber(id)] = v.value
end
proxy:restore()
proxy = upgrade(vars, OFF)
T.eq(
  "the restart tells the level once again, at the 0 the proxy shows",
  { changes(proxy).level, proxy.level },
  { 1, 0 }
)
T.eq("and its capabilities once again", proxy:count("DYNAMIC_CAPABILITIES_CHANGED"), 1)
proxy:restore()

T.section("a night light left on, in a preset's color, at half")
-- The release's proxy as it would show a lit light: Aqua Morning, the setup's own preset, at 50.
local AQUA = { x = 0.147231, y = 0.358549 }
local lit = {}
for id, v in pairs(release.variables) do
  lit[id] = v
end
lit[1000], lit[1001], lit[1110] = "1", "50", "50"
lit[1200] = string.format("%s,%s,0", AQUA.x, AQUA.y)
lit[1210] = lit[1200]
local r, g, b = Color.xyToRGB(AQUA.x, AQUA.y)
emptyStore()
proxy = upgrade(lit, {
  online = true,
  on = true,
  red = round(r * 255),
  green = round(g * 255),
  blue = round(b * 255),
  brightnessPct = 50,
})
T.eq("the start tells the level once, at the 50 the proxy shows", { changes(proxy).level, proxy.level }, { 1, 50 })
T.eq("and the color once", changes(proxy).color, 1)
T.truthy(
  "at the Aqua Morning the proxy shows",
  proxy.color
    and math.abs(tonumber(proxy.color.x) - AQUA.x) <= 0.01
    and math.abs(tonumber(proxy.color.y) - AQUA.y) <= 0.01
)
T.eq("and its capabilities once", proxy:count("DYNAMIC_CAPABILITIES_CHANGED"), 1)
proxy:restore()

T.section("a night light whose proxy holds an integrator's own rates and Min and Max On")
local edited = release.setup
for key, value in pairs({
  CLICK_RATE_UP = 400,
  CLICK_RATE_DOWN = 900,
  HOLD_RATE_UP = 3000,
  HOLD_RATE_DOWN = 4000,
  MIN_ON_LEVEL = 10,
  MAX_ON_LEVEL = 90,
}) do
  edited = edited:gsub("<" .. key .. ">%d+</" .. key .. ">", "<" .. key .. ">" .. value .. "</" .. key .. ">", 1)
end
emptyStore()
proxy, light = upgrade(release.variables, OFF, edited)
s = light.settings
T.eq("the light takes Min and Max On from the proxy", { s:onRange() }, { 10, 90 })
T.eq("and the click and hold rates", { s:clickRate(true), s:clickRate(false), s:holdRate(true), s:holdRate(false) }, {
  400,
  900,
  3000,
  4000,
})
proxy:restore()

T.finish()

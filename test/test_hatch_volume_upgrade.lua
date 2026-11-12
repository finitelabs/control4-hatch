-- The v20261111 Volume upgraded in place to the light library: over the proxy the release left, as a controller holds
-- it (hatch_v20261111_proxies.lua) and an empty store, the dimmer reads the proxy's settings as they were, tells no
-- Brightness Changed for a device that is as the proxy shows it, and tells its capabilities at most once, with none
-- again after a restart.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_hatch_volume_upgrade.lua

require("c4_shim")
require("c4_local")
local T = require("testlib")
local F = require("c4_fixtures")
local Fake = require("light_proxy_fake")
local release = require("hatch_v20261111_proxies").volume

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
  ShimDofileBuild(HERE .. "../drivers/hatch_volume/driver.lua", "oss")
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

-- Stopped, at the volume it keeps.
local OFF = { online = true, on = false, brightnessPct = 35 }

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

T.section("a volume left stopped")
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
T.eq("no Brightness or Color Changed", changes(proxy), { level = 0, color = 0 })
T.truthy("the capabilities told at most once", proxy:count("DYNAMIC_CAPABILITIES_CHANGED") <= 1)
T.eq("and online", proxy.online, true)

T.section("then a Director restart")
local vars = {}
for id, v in pairs(proxy.vars) do
  vars[tonumber(id)] = v.value
end
proxy:restore()
proxy = upgrade(vars, OFF)
T.eq("no Brightness or Color Changed", changes(proxy), { level = 0, color = 0 })
T.eq("and no capabilities", proxy:count("DYNAMIC_CAPABILITIES_CHANGED"), 0)
proxy:restore()

T.section("a volume left playing at 40")
local playing = {}
for id, v in pairs(release.variables) do
  playing[id] = v
end
playing[1000], playing[1001], playing[1110] = "1", "40", "40"
emptyStore()
proxy = upgrade(playing, { online = true, on = true, brightnessPct = 40 })
T.eq("no Brightness Changed", changes(proxy), { level = 0, color = 0 })
T.truthy("the capabilities told at most once", proxy:count("DYNAMIC_CAPABILITIES_CHANGED") <= 1)
proxy:restore()

T.section("a volume whose proxy holds an integrator's own rates and Min and Max On")
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

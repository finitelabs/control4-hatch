-- The Hatch Volume dimmer as a light: the brightness preset a level names is told with it, a rebind forgets the
-- device it was bound to, and a lost link to Hatch reads off while the account's own stop leaves it as it was.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_hatch_volume.lua

require("c4_shim")
require("c4_local")
local T = require("testlib")

-- This is the released Volume's suite, run once against the light library. Each assertion the library answers
-- differently says so above it: "Differs (section 6)" names a row of the design's section 6.

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
local PROXY, COORD = 5001, 5002

local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  return section == "minimum_os_version" and "3.3.0" or configInfo(self, section)
end

-- Turning on reads the proxy's Default On level; this proxy has none.
function C4:GetProxyDevices()
  return nil
end

local told = {}
function C4:SendToProxy(id, command, params)
  told[#told + 1] = { id = id, command = command, params = params or {} }
end

Properties["Driver Status"] = ""
Properties["Turn On Plays"] = ""
ShimDofileBuild(HERE .. "../drivers/hatch_volume/driver.lua", "oss")
OnDriverInit()
OnDriverLateInit()

local function mark()
  told = {}
end

local function proxy(command, params)
  ReceivedFromProxy(PROXY, command, params or {})
end

--- The command of each ENTITY_COMMAND sent to the Hatch driver since the mark.
local function commands()
  local out = {}
  for _, t in ipairs(told) do
    if t.id == COORD and t.command == "ENTITY_COMMAND" then
      out[#out + 1] = (DeserializeSafe(t.params.body) or {}).command
    end
  end
  return out
end

--- The Hatch driver's state for the volume: playing at `level`, or stopped.
local function report(on, level)
  ReceivedFromProxy(COORD, "UPDATE_STATE", {
    state = SerializeSafe({ online = true, on = on, brightnessPct = level or 0 }),
  })
end

--- What the proxy was told since the mark, in order, as "online=<state>" and "level=<n>[/<preset>]".
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
    end
  end
  return out
end

T.section("a level's brightness preset is told with the level, until another level command")
report(true, 30)
mark()
proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 3 })
report(true, 60)
-- Differs (section 6): told as the command goes out.
T.eq("a level naming a preset: told in it", toldInOrder(), { "level=60/3" })
mark()
proxy("SET_LEVEL", { LEVEL = 40 })
report(true, 40)
T.eq("a level naming none: told in none", toldInOrder(), { "level=40" })

T.section("a rebind forgets the device the volume was bound to")
mark()
OBC[COORD](COORD, "HATCH_VOLUME", true)
T.eq("the proxy is told offline, not the old device's state", toldInOrder(), { "online=false" })
mark()
proxy("TOGGLE")
-- Differs (the device gate, accepted by the light library): no command reaches a device that has not reported.
T.eq("and a Toggle before the new device reports does nothing", commands(), {})
report(false, 0)

T.section("a lost link to Hatch reads off; the account's own stop leaves the volume as it was")
report(true, 40)
mark()
ReceivedFromProxy(COORD, "UPDATE_DISCONNECT", {})
T.eq("a lost link: offline, then off", toldInOrder(), { "online=false", "level=0" })
report(true, 40)
mark()
ReceivedFromProxy(COORD, "UPDATE_DISCONNECT", { suspended = true })
T.eq("the account's own stop: offline only", toldInOrder(), { "online=false" })

-- ─── What On plays, and at what volume ─────────────────────────────────────
-- These pin the released volume's turn-on before it moves to the light library.

--- Each ENTITY_COMMAND body sent to the Hatch driver since the mark.
local function bodies()
  local out = {}
  for _, t in ipairs(told) do
    if t.id == COORD and t.command == "ENTITY_COMMAND" then
      out[#out + 1] = DeserializeSafe(t.params.body) or {}
    end
  end
  return out
end

ReceivedFromProxy(COORD, "UPDATE_STATE", {
  sounds = SerializeSafe({ { id = 7, title = "Rain" } }),
  favorites = SerializeSafe({ { id = 3, name = "Bedtime", steps = { { sound = { v = 13107 } } } } }),
  state = SerializeSafe({ online = true, on = false, brightnessPct = 35 }),
})

T.section("a sound's start carries no volume, as the proxy holds no Default On level, and a level from off carries it")
Properties["Turn On Plays"] = "Sound: Rain"
mark()
proxy("ON")
-- Differs: the ON carries the volume the Hatch last told, so the sound starts where the Hatch would resume it.
T.eq("an ON: the sound, at the volume the Hatch keeps", bodies(), { { command = "on", soundId = 7, brightness = 35 } })
report(true, 35)
proxy("OFF")
report(false, 35)
mark()
proxy("SET_LEVEL", { LEVEL = 60 })
T.eq("a level from off: the sound at that level", bodies(), { { command = "on", soundId = 7, brightness = 60 } })
report(true, 60)

T.section("a favorite's ON carries no volume, and its level shows when the Hatch driver tells it")
report(false, 35)
Properties["Turn On Plays"] = "Favorite: Bedtime"
mark()
proxy("ON")
T.eq("the favorite alone", bodies(), { { command = "on", favoriteId = 3 } })
-- Differs (section 6): the favorite's own level is told once, as the command goes out.
T.eq("the proxy is told the favorite's own level at once", toldInOrder(), { "level=20" })
report(true, 20)
T.eq("and its report tells nothing more", toldInOrder(), { "level=20" })

T.section("ON while playing starts the chosen favorite again")
mark()
proxy("ON")
-- Differs (section 6): ON while playing is a volume set to the level it plays at, so play continues.
T.eq("nothing, so the favorite plays on", bodies(), {})
report(false, 20)
Properties["Turn On Plays"] = ""

T.section("the build declares only what the volume does")
do
  local made = require("lib.light").made
  local caps = {}
  for _, row in ipairs(require("lib.light.caps").static(made[#made].profile)) do
    caps[row.key] = row.value
  end
  for _, name in ipairs({ "dimmer", "set_level", "supports_target", "on_off" }) do
    T.eq(name .. " is True", caps[name], "True")
  end
  -- Differs, asked of the light library: ramp_level follows dimming, so the build declares it True.
  T.eq("ramp_level is True", caps.ramp_level, "True")
  for _, name in ipairs({
    "supports_color",
    "supports_default_on",
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

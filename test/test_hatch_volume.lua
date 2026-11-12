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
T.eq("a level naming a preset: told in it", toldInOrder()[2], "level=60/3")
mark()
proxy("SET_LEVEL", { LEVEL = 40 })
report(true, 40)
T.eq("a level naming none: told in none", toldInOrder()[2], "level=40")

T.section("a rebind forgets the device the volume was bound to")
mark()
OBC[COORD](COORD, "HATCH_VOLUME", true)
T.eq("the proxy is told offline, not the old device's state", toldInOrder(), { "online=false" })
mark()
proxy("TOGGLE")
T.eq("and a Toggle before the new device reports turns it on, not off as the old one was", commands(), { "on" })
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
T.eq("an ON: the sound, with no volume, so the Hatch keeps its own", bodies(), { { command = "on", soundId = 7 } })
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
T.eq("the proxy is told no level yet", toldInOrder(), {})
report(true, 20)
T.eq("then the favorite's own", toldInOrder(), { "online=true", "level=20" })

T.section("ON while playing starts the chosen favorite again")
mark()
proxy("ON")
T.eq("the favorite again, which restarts it", bodies(), { { command = "on", favoriteId = 3 } })
report(false, 20)
Properties["Turn On Plays"] = ""

T.section("driver.xml declares only what the volume does")
do
  local f = assert(io.open(HERE .. "../drivers/hatch_volume/driver.xml"))
  local caps = f:read("*a"):match("<capabilities>(.-)</capabilities>")
  f:close()
  local function cap(name)
    return caps:match("<" .. name .. ">(.-)</" .. name .. ">")
  end
  for _, name in ipairs({ "dimmer", "set_level", "supports_target", "on_off" }) do
    T.eq(name .. " is True", cap(name), "True")
  end
  for _, name in ipairs({
    "supports_color",
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
    T.eq(name .. " is False", cap(name), "False")
  end
end

T.section("every capability driver.xml declares has the proxy commands it brings")
require("light_capabilities").checkHandlers(T, HERE .. "../drivers/hatch_volume/driver.xml")

T.finish()

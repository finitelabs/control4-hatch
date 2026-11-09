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

T.finish()

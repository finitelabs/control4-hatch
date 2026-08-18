-- The playback-intent guard: after a stop, a stale "playing" re-pushed by a
-- reload must not re-select the room (which would fight the stop and oscillate).
--
-- Run from the driver root:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_media_intent_guard.lua

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

local PROXY = "2839"
local ROOM = 292
-- Controllable room variables: 1000 = foreground device, 1001 = audio device.
local roomVars = { [1000] = "0", [1001] = "0", [1010] = "1" }

C4.RoomGetId = function()
  return ROOM
end
C4.GetProxyDevices = function()
  return PROXY
end
C4.GetDeviceVariable = function(_self, _dev, var)
  return roomVars[var] or "0"
end
C4.FireEvent = function() end

-- Model the room's response to our select/release so the guards see real state.
local sentToDevice = {}
C4.SendToDevice = function(_self, _dev, command)
  table.insert(sentToDevice, command)
  if command == "SELECT_AUDIO_DEVICE" then
    roomVars[1000], roomVars[1001], roomVars[1010] = PROXY, PROXY, "1"
  elseif command == "ROOM_OFF" then
    roomVars[1000], roomVars[1001], roomVars[1010] = "0", "0", "0"
  end
end

-- Capture the intent-clear timer so the test can lapse the window on demand.
local timers = {}
SetTimer = function(name, _ms, cb)
  timers[name] = cb
  return name
end
CancelTimer = function(name)
  timers[name] = nil
end

dofile("drivers/hatch_media/driver.lua")

-- Capture coordinator sends so the test can assert a state refresh is requested.
local sentToProxy = {}
SendToProxy = function(_binding, command)
  table.insert(sentToProxy, command)
end
local function refreshCount()
  local n = 0
  for _, c in ipairs(sentToProxy) do
    if c == "REFRESH_STATE" then
      n = n + 1
    end
  end
  return n
end

local COORD_BINDING, PROXY_BINDING = 6001, 5001

local function pushState(playing)
  ReceivedFromProxy(
    COORD_BINDING,
    "UPDATE_STATE",
    { state = SerializeSafe({ isPlaying = playing, soundId = 1, soundTitle = "Rain" }) }
  )
end

local function selectCount()
  local n = 0
  for _, c in ipairs(sentToDevice) do
    if c == "SELECT_AUDIO_DEVICE" then
      n = n + 1
    end
  end
  return n
end

-- 1) First playing state (the reload reconcile) claims the room.
sentToDevice = {}
pushState(true)
check("first playing state selects the room", selectCount() == 1, "selects=" .. selectCount())

-- 2) We issue a stop (Navigator OFF -> entityCommand stop), arming intent=stopped.
ReceivedFromProxy(PROXY_BINDING, "STOP", {})
-- The coordinator acknowledges the stop, so the room releases and wasPlaying
-- goes false -- the state a lagging echo then contradicts.
pushState(false)

-- 3) The coordinator re-pushes the stale "playing" state. The guard must drop it.
sentToDevice = {}
pushState(true)
check("a stale playing echo after a stop does not re-select", selectCount() == 0, "selects=" .. selectCount())

-- 4) The guard is time-bounded: once the window lapses, the echo is honoured.
--    Free the room, clear the guard, then a fresh not-playing -> playing selects.
check("intent guard armed a bounded timer", type(timers["PlaybackIntent"]) == "function")
timers["PlaybackIntent"]()
roomVars[1000], roomVars[1001], roomVars[1010] = "0", "0", "0"
pushState(false)
sentToDevice = {}
pushState(true)
check("after the window a genuine playing selects again", selectCount() == 1, "selects=" .. selectCount())

-- 5) Dropping an echo is not losing it: closing the window pulls fresh state so
--    any field that echo also carried (online, volume, card) is not stranded.
ReceivedFromProxy(PROXY_BINDING, "STOP", {})
pushState(false)
sentToProxy = {}
pushState(true)
timers["PlaybackIntent"]()
check(
  "dropping an echo requests a state refresh when the window closes",
  refreshCount() == 1,
  "refreshes=" .. refreshCount()
)

-- 6) A window that dropped nothing does not refresh, so a normal stop stays quiet.
ReceivedFromProxy(PROXY_BINDING, "STOP", {})
pushState(false)
sentToProxy = {}
timers["PlaybackIntent"]()
check("a window that dropped nothing does not refresh", refreshCount() == 0, "refreshes=" .. refreshCount())

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end

-- The Hatch driver's companions while the account has lost its connection to Hatch: one that asks for its state or
-- is bound is told the account is disconnected, not the last state, which it would show as live; and a Hatch Volume
-- On that plays a favorite, which cannot go out, tells it no level. Connected, both are answered with state.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_companions_offline.lua

require("c4_shim")
require("c4_local")
local T = require("testlib")
local deferred = require("deferred")
local bindings = require("lib.bindings")
local Api = require("hatch.api")
local Connection = require("hatch.connection")

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
local DEVICES = { { thingName = "thing-1", name = "Test Nursery", product = "riot", macAddress = "02005E005301" } }
local FAVORITE = { id = 7, name = "Bedtime", steps = { { enabled = true, sound = { id = 3, v = 32768 } } } }
local SHADOW = {
  connected = true,
  current = {
    playing = "none",
    sound = { id = 3, v = 16384 },
    color = { id = 1, r = 255, g = 255, b = 255, i = 16384 },
  },
}

Api.fetchSounds = function()
  return deferred.new():resolve({ { id = 3, title = "Rain" } })
end
Api.fetchSoundArtwork = function()
  return deferred.new():resolve({})
end
Api.fetchRoutines = function()
  return deferred.new():resolve({ FAVORITE })
end

-- Hatch's MQTT link without a socket: each publish is kept, and the test says when the link is up.
local live
local published = 0
Connection.sendMqtt = function()
  published = published + 1
end
Connection.start = function(self)
  live = self
  self.stopped, self.connected = false, true
  self.onConnected(DEVICES)
end
Connection.stop = function(self)
  self.stopped, self.connected = true, false
end
local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.0"
  elseif section == "version" then
    return "20261105"
  end
  return configInfo(self, section)
end
function C4:GetVersionInfo()
  return { version = "3.3.0.0-res" }
end
function C4:GetUniqueMAC()
  return "02:00:5E:00:53:01"
end

local told = {}
function C4:SendToProxy(id, command, params)
  told[#told + 1] = { id = id, command = command, params = params or {} }
end

Properties["Email"] = "user@example.test"
Properties["Password"] = "test-password-not-real"
Properties["Automatic Updates"] = "Off"
Properties["Connection Status"] = ""
Properties["Driver Status"] = ""
Properties["Devices"] = ""
ShimDofileBuild(HERE .. "../drivers/hatch/driver.lua", "oss")
OnDriverInit()
OnDriverLateInit("DIT_ADDED")
live.onShadow("thing-1", SHADOW)

local function binding(ns)
  return bindings:getDynamicBinding(ns, "thing-1").bindingId
end

--- What the companion on `ns` is told while `fn` runs.
local function toldTo(ns, fn)
  local from = #told
  fn()
  local out = {}
  for i = from + 1, #told do
    local t = told[i]
    if t.id == binding(ns) and t.command == "UPDATE_DISCONNECT" then
      out[#out + 1] = "disconnected"
    elseif t.id == binding(ns) and t.command == "UPDATE_STATE" then
      local state = DeserializeSafe(t.params.state) or {}
      out[#out + 1] = string.format(
        "online=%s on=%s level=%s",
        tostring(state.online),
        tostring(state.on),
        tostring(state.brightnessPct or state.volumePct)
      )
    end
  end
  return table.concat(out, "; ")
end

local function refresh(ns)
  return function()
    ReceivedFromProxy(binding(ns), "REFRESH_STATE", {})
  end
end

local function bind(ns)
  return function()
    OBC[binding(ns)](binding(ns), ns, true)
  end
end

local function playFavorite()
  local body = SerializeSafe({ command = "on", favoriteId = FAVORITE.id })
  ReceivedFromProxy(binding("HATCH_VOLUME"), "ENTITY_COMMAND", { body = body })
end

T.section("Connected, a companion is told the device's state")
do
  T.eq("the night light asking for it", toldTo("HATCH_LIGHT", refresh("HATCH_LIGHT")), "online=true on=true level=25")
  T.eq("the volume bound", toldTo("HATCH_VOLUME", bind("HATCH_VOLUME")), "online=true on=false level=25")
  local before = published
  T.eq("a favorite's level at once", toldTo("HATCH_VOLUME", playFavorite), "online=true on=true level=50")
  T.eq("and the favorite goes out", published, before + 1)
end

T.section("Once the connection drops, a companion is told the account is disconnected")
do
  T.eq(
    "at the drop",
    toldTo("HATCH_LIGHT", function()
      live.connected = false
      live:announceDown()
    end),
    "disconnected"
  )
  T.eq("the night light asking for its state", toldTo("HATCH_LIGHT", refresh("HATCH_LIGHT")), "disconnected")
  T.eq("the volume bound", toldTo("HATCH_VOLUME", bind("HATCH_VOLUME")), "disconnected")
  T.eq("the sound machine asking for its state", toldTo("HATCH_MEDIA", refresh("HATCH_MEDIA")), "disconnected")
  local before = published
  T.eq("a favorite that cannot go out shows no level", toldTo("HATCH_VOLUME", playFavorite), "")
  T.eq("and nothing is published", published, before)
end

T.section("Connected again, a companion is told the state at once")
do
  T.eq(
    "the night light, as the account reconnects",
    toldTo("HATCH_LIGHT", function()
      live.connected = true
      live.announcedDown = false
      live.onConnected(DEVICES)
    end),
    "online=true on=true level=25"
  )
end

T.finish()

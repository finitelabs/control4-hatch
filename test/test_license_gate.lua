-- The Hatch account's license gate in the DriverCentral build, driven by the real cloud client against a fake
-- Cloud driver, with Hatch's API and MQTT connection stood in by recorders. Licensed, the account logs in and its
-- companions' commands reach the device shadow; five minutes without a license stop the connection and tell the
-- companions, which are told so again when they ask and shown no level for a command; a license connects it again at
-- once. With no product id yet the account is stopped from its load.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_gate.lua

require("c4_shim")
require("c4_local")
local T = require("testlib")
local cloud = require("dc_cloud")
local deferred = require("deferred")
local bindings = require("lib.bindings")

local DRIVER = (debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./") .. "../drivers/hatch/driver.lua"

-- Hatch's cloud: each connection the account opens, and each shadow update it sends. The account has one favorite.
local starts, stops, shadows, last = 0, 0, {}, nil
local FAVORITE = { id = 7, name = "Bedtime", steps = { { enabled = true, sound = { id = 3, v = 32768 } } } }
package.loaded["hatch.api"] = {
  new = function()
    return setmetatable({}, {
      __index = function(_, name)
        return function()
          local d = deferred.new()
          if name == "fetchRoutines" then
            d:resolve({ FAVORITE })
          end
          return d
        end
      end,
    })
  end,
}
package.loaded["hatch.connection"] = {
  new = function(_, opts)
    last = {
      opts = opts,
      up = false,
      start = function()
        starts = starts + 1
      end,
      stop = function(self)
        stops = stops + 1
        self.up = false
      end,
      isConnected = function(self)
        return self.up
      end,
      updateShadow = function(self, thing, desired)
        if not self.up then
          return false
        end
        shadows[#shadows + 1] = { thing = thing, desired = desired }
        return true
      end,
    }
    return last
  end,
}

local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.0"
  elseif section == "version" then
    return "20261104"
  end
  return configInfo(self, section)
end
function C4:GetVersionInfo()
  return { version = "3.3.0.0-res" }
end
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
local disconnects, states, lastTo, lastSuspended = 0, 0, {}, {}
function C4:SendToProxy(id, command, params)
  if command == "UPDATE_DISCONNECT" then
    disconnects = disconnects + 1
    lastSuspended[id] = (params or {}).suspended
  elseif command == "UPDATE_STATE" then
    states = states + 1
  end
  lastTo[id] = command
end

local gate

--- A load of the account driver with a fresh client and gate; a licensed one connects and finds one device.
--- @param answer? table What the Cloud driver answers each ping with; nil answers nothing.
--- @param pid? integer The product id (999).
local function load(answer, pid)
  if gate and gate._timer then
    gate._timer:Cancel()
  end
  package.loaded["cloud-client-byte"] = nil
  package.loaded["lib.drivercentral"] = nil
  cloud.ping, cloud.answer, cloud.silent, cloud.present = nil, answer, answer == nil, true
  starts, stops, last = 0, 0, nil
  Properties = {
    ["Driver Status"] = "",
    ["Driver Version"] = "",
    ["Cloud Status"] = "",
    ["Automatic Updates"] = "Off",
    ["Email"] = "user@example.com",
    ["Password"] = "not-a-password",
    ["Connection Status"] = "",
    ["Devices"] = "",
  }
  DC_OnDriverStatus = nil
  ShimDofileBuild(DRIVER, "drivercentral")
  gate = require("lib.drivercentral")
  gate.PRODUCT_ID = pid or 999
  OnDriverInit()
  OnDriverLateInit("DIT_ADDED")
  if last then
    last.up = true
    last.opts.onConnected({ { thingName = "thing-1", name = "Nursery", product = "restPlus" } })
  end
end

--- `n` rounds of 10 s: one ping, then one read by the gate.
local function tick(n)
  for _ = 1, n or 1 do
    if cloud.ping then
      cloud.poll(1)
    end
    gate:_check()
  end
end

--- A bound night light's ON, as its companion sends it.
local function lightOn()
  local light = bindings:getDynamicBinding("HATCH_LIGHT", "thing-1")
  ReceivedFromProxy(light.bindingId, "ENTITY_COMMAND", { body = SerializeSafe({ command = "on", brightness = 50 }) })
end

T.section("A licensed account connects, and a companion's command reaches the device")
do
  load({ AC = 1, AS = "License Activated" })
  T.eq("connected once", starts, 1)
  tick(40)
  local n = #shadows
  lightOn()
  T.eq("a light ON updates the shadow after 400 s", #shadows, n + 1)
end

T.section("Without a license the account disconnects five minutes after its load, and nothing reaches Hatch")
do
  load({ AC = 0, AS = "Invalid License" })
  tick(29)
  T.eq("29 reads of 0: no stop yet", stops, 0)
  local told = disconnects
  tick()
  T.eq("the 30th read stops the connection", stops, 1)
  T.eq("the companions are told", disconnects > told, true)
  T.eq("Driver Status says why", Properties["Driver Status"], "No active license")
  T.eq("and Connection Status", Properties["Connection Status"], "No active license")
  local n = #shadows
  lightOn()
  ExecuteCommand("LUA_ACTION", { ACTION = "Reconnect" })
  OnPropertyChanged("Password")
  T.eq("a command, Reconnect and a credential edit open nothing", starts, 1)
  T.eq("and send no shadow update", #shadows, n)
  local volume = bindings:getDynamicBinding("HATCH_VOLUME", "thing-1").bindingId
  ReceivedFromProxy(volume, "REFRESH_STATE", {})
  T.eq("a companion asking for its state is told the account is disconnected", lastTo[volume], "UPDATE_DISCONNECT")
  T.eq("by its own stop, so the device is as it was", lastSuspended[volume], true)
  local pushed = states
  ReceivedFromProxy(volume, "ENTITY_COMMAND", { body = SerializeSafe({ command = "on", favoriteId = FAVORITE.id }) })
  T.eq("and a Volume On that plays a favorite shows it no level", states, pushed)
end

T.section("A license back connects the account again at once")
do
  load({ AC = -1, AS = "Trial Running, 1 Hours Remaining" })
  cloud.answer = { AC = 0, AS = "Trial Expired" }
  tick(30)
  T.eq("stopped", stops, 1)
  cloud.answer = { AC = 1, AS = "License Activated" }
  cloud.say(cloud.answer)
  T.eq("connected again without waiting for a read", starts, 2)
  T.eq("Driver Status back", Properties["Driver Status"], "Ready")
end

T.section("A Cloud driver update leaves a licensed account connected")
do
  load({ AC = 1, AS = "License Activated" })
  tick(3)
  cloud.say({ AC = 0, AS = "Cloud driver removed, please install cloud driver." })
  cloud.silent = true
  tick(3)
  cloud.silent = false
  tick(40)
  T.eq("never stopped", stops, 0)
end

T.section("With no product id yet the account is stopped from its load")
do
  load({ AC = 1, AS = "License Activated" }, 0)
  T.eq("the client is not loaded", package.loaded["cloud-client-byte"], nil)
  T.eq("nothing connects", starts, 0)
  T.eq("Driver Status", Properties["Driver Status"], "No active license")
  tick(40)
  T.eq("and nothing does later", starts, 0)
end

if gate and gate._timer then
  gate._timer:Cancel()
end
T.finish()

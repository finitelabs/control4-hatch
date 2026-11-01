-- With Cloud Monitoring on, an error the Hatch drivers' fallback paths catch is reported: a WebSocket callback (the
-- module runs each in a pcall of its own), the socket failing to open or to close, an auth chain or a catalog fetch
-- that fails other than over HTTP, and the Sound Machine's late init steps. An HTTP failure is not reported.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_cloud_monitoring_fallbacks.lua

local T = require("testlib")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

local deferred = require("deferred")
local diagnostics = require("lib.diagnostics")
local WebSocket = require("drivers-common-public.module.websocket")
local Api = require("hatch.api")
local Connection = require("hatch.connection")

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"

-- This build carries no server, so Cloud Monitoring is turned on here and each error report is taken where it would
-- be written.
local reported = {}
diagnostics._enabled = true
function diagnostics:_writeErrorLog(message, _, source)
  reported[#reported + 1] = source .. ": " .. tostring(message):gsub("^.-:%d+: ", "")
end

--- What `fn` got reported, as "source: message", each call in a rate window of its own.
local function reports(fn)
  reported = {}
  diagnostics._errorWriteCount = 0
  fn()
  return reported
end

local function raises(message)
  return function()
    error(message)
  end
end

local HTTP_FAILURE =
  { error = "HTTP GET request to https://api.example.test/x failed with status code 500", code = 500 }

-- The OS the drivers ask for.
local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  return section == "minimum_os_version" and "3.3.0" or configInfo(self, section)
end
function C4:GetVersionInfo()
  return { version = "4.3.0" }
end

-- Sockets that open nothing, with the module's own callback setters.
local sockets = {}
local newSocket = WebSocket.new
local function fakeSocket()
  local ws = setmetatable({
    Start = function() end,
    Send = function() end,
    delete = function(_, done)
      if done then
        done()
      end
    end,
  }, { __index = WebSocket })
  sockets[#sockets + 1] = ws
  return ws
end
WebSocket.new = fakeSocket

local CREDS = {
  endpoint = "example.iot.us-east-1.amazonaws.com",
  region = "us-east-1",
  accessKey = "AKIDEXAMPLE",
  secretKey = "test-secret-not-real",
  sessionToken = "test-session-not-real",
}

local conn = Connection:new({ api = {} })
conn.stopped = false
conn:openSocket(CREDS)
local ws = sockets[#sockets]

T.section("a WebSocket callback that fails is reported")
do
  conn.onWsEstablished = raises("established boom")
  conn.onWsMessage = raises("frame boom")
  conn.onWsClosed = raises("closed boom")
  T.eq(
    "the handshake",
    reports(function()
      ws.Established(ws)
    end),
    { "Hatch.WsEstablished: established boom" }
  )
  T.eq(
    "a message",
    reports(function()
      ws.ProcessMessage(ws, "\208\0")
    end),
    { "Hatch.WsMessage: frame boom" }
  )
  T.eq(
    "a close by the server",
    reports(function()
      ws.ClosedByRemote(ws)
    end),
    { "Hatch.WsClosedByRemote: closed boom" }
  )
  T.eq(
    "the network dropping",
    reports(function()
      ws.Offline(ws)
    end),
    { "Hatch.WsOffline: closed boom" }
  )
  conn.onWsEstablished, conn.onWsMessage, conn.onWsClosed = nil, nil, nil

  conn.handlePacket = raises("packet boom")
  T.eq(
    "a packet the connection fails on is reported once",
    reports(function()
      ws.ProcessMessage(ws, "\208\0") -- PINGRESP
    end),
    { "Hatch.onWsMessage: packet boom" }
  )
  conn.handlePacket = nil
end

T.section("a socket that fails to open or to close is reported")
do
  WebSocket.new = function() end
  T.eq(
    "an open that makes no socket",
    reports(function()
      conn:openSocket(CREDS)
    end),
    { "Hatch.SocketOpen: WebSocket:new returned nil" }
  )
  WebSocket.new = fakeSocket

  local done = false
  conn.ws = fakeSocket()
  conn.ws.delete = raises("delete boom")
  T.eq(
    "a close that raises",
    reports(function()
      conn:teardownSocket(function()
        done = true
      end)
    end),
    { "Hatch.SocketDelete: delete boom" }
  )
  T.truthy("and the next socket still opens", done)
end

T.section("an auth chain that fails other than over HTTP is reported")
do
  conn.api = {
    connect = function()
      return deferred.new():reject("login failed: no token in response")
    end,
  }
  T.eq(
    "a reply the driver cannot read",
    reports(function()
      conn:connectOnce()
    end),
    { "Hatch.AuthChain: login failed: no token in response" }
  )
  conn.api.connect = function()
    return deferred.new():reject(HTTP_FAILURE)
  end
  T.eq(
    "an HTTP failure is not",
    reports(function()
      conn:connectOnce()
    end),
    {}
  )
  conn:stop()
end

T.section("a catalog fetch that fails other than over HTTP is reported")
do
  local fetchSounds, fetchRoutines, start, stop = Api.fetchSounds, Api.fetchRoutines, Connection.start, Connection.stop
  local why = "a Lua error"
  Api.fetchSounds = function()
    return deferred.new():reject(why == "http" and HTTP_FAILURE or "sounds boom")
  end
  Api.fetchRoutines = function()
    return deferred.new():reject(why == "http" and HTTP_FAILURE or "favorites boom")
  end
  Connection.start = function(self)
    self.onConnected({ { thingName = "thing-1", name = "Test Nursery", product = "riot", macAddress = "02005E005301" } })
  end
  Connection.stop = function() end
  function C4:GetUniqueMAC()
    return "02:00:5E:00:53:01"
  end
  Properties["Email"] = "user@example.test"
  Properties["Password"] = "test-password-not-real"
  dofile(HERE .. "../drivers/hatch/driver.lua")
  T.eq(
    "the sounds and the favorites",
    reports(function()
      OnDriverLateInit()
    end),
    { "Hatch.SoundFetch: sounds boom", "Hatch.FavoriteFetch: favorites boom" }
  )
  why = "http"
  T.eq(
    "an HTTP failure is not",
    reports(function()
      OnPropertyChanged("Email")
    end),
    {}
  )
  Api.fetchSounds, Api.fetchRoutines, Connection.start, Connection.stop = fetchSounds, fetchRoutines, start, stop
  Properties["Email"], Properties["Password"] = nil, nil
end

T.section("the Sound Machine's late init steps that fail are reported")
do
  C4.GetBoundPartner = raises("partner boom")
  C4.RoomGetId = raises("room boom")
  dofile(HERE .. "../drivers/hatch_media/driver.lua")
  T.eq(
    "hiding the amplifier, and watching the room",
    reports(function()
      OnDriverLateInit()
    end),
    { "HatchMedia.HideAmplifier: partner boom", "HatchMedia.WatchRooms: room boom" }
  )
end

WebSocket.new = newSocket
KillAllTimers()
T.finish()

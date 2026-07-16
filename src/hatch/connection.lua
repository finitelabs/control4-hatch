-- Hatch AWS IoT connection orchestrator.
--
-- Ties the whole cloud transport together and hides it behind a small surface:
--   auth chain (api.lua) -> SigV4 presign (sigv4.lua) -> C4 WebSocket (fixed
--   vendored module) -> binary MQTT (mqtt.lua) -> device shadows.
--
-- Responsibilities: open/keep the socket, MQTT CONNECT + CONNACK, subscribe to
-- each device's shadow topics, decode inbound shadow documents, publish desired
-- state, MQTT keepalive, refresh temporary AWS creds before they expire, and
-- reconnect with backoff. Callers get onConnected / onShadow callbacks and the
-- updateShadow() / getShadow() methods.

local SigV4 = require("hatch.sigv4")
local MQTT = require("hatch.mqtt")
local WebSocket = require("drivers-common-public.module.websocket")
local JSON = require("JSON")
local log = require("lib.logging")

local SHADOW_PREFIX = "$aws/things/"
local KEEPALIVE_SECONDS = 60
local PING_INTERVAL_MS = 30 * ONE_SECOND -- MQTT PINGREQ cadence (must be < keepalive)
local REFRESH_MARGIN_MS = 5 * ONE_MINUTE -- refresh creds this long before they expire
local RECONNECT_MIN_MS = 2 * ONE_SECOND
local RECONNECT_MAX_MS = 2 * ONE_MINUTE
local CONNECT_TIMEOUT_MS = 20 * ONE_SECOND -- give up on a stalled WS/MQTT handshake and retry
local WS_BINARY = 0x82

--- @class HatchConnection
local Connection = {}
Connection.__index = Connection

--- @param opts table {
---   api          HatchApi instance,
---   onConnected  function(devices)  -- fired on MQTT CONNACK rc=0,
---   onShadow     function(thingName, reported, desired),
---   onDisconnected function(),
---   clientId?    string,
--- }
function Connection:new(opts)
  local instance = setmetatable({}, self)
  instance.api = opts.api
  instance.onConnected = opts.onConnected
  instance.onShadow = opts.onShadow
  instance.onDisconnected = opts.onDisconnected
  instance.clientId = opts.clientId or ("control4-hatch-" .. tostring(math.random(100000, 999999)))
  instance.devices = {}
  instance.connected = false -- true once MQTT CONNACK rc=0 seen
  instance.stopped = true
  instance.buffer = ""
  instance.packetId = 0
  instance.reconnectDelay = RECONNECT_MIN_MS
  return instance
end

function Connection:isConnected()
  return self.connected
end

function Connection:getDevices()
  return self.devices
end

function Connection:nextPacketId()
  self.packetId = (self.packetId % 65535) + 1
  return self.packetId
end

--- Extract the thing name from a `$aws/things/<thing>/shadow/...` topic.
local function thingFromTopic(topic)
  return topic:match("^%$aws/things/(.-)/shadow")
end

-- ---- lifecycle -----------------------------------------------------------

function Connection:start()
  self.stopped = false
  self:connectOnce()
end

function Connection:stop()
  self.stopped = true
  self.connected = false
  CancelTimer(self.pingTimer)
  CancelTimer(self.refreshTimer)
  CancelTimer(self.reconnectTimer)
  CancelTimer(self.connectTimer)
  self.pingTimer, self.refreshTimer, self.reconnectTimer, self.connectTimer = nil, nil, nil, nil
  self:teardownSocket()
end

--- Tear down the current socket, invoking onComplete once its binding is freed.
--- @param onComplete? fun() called after the module finishes releasing the binding
function Connection:teardownSocket(onComplete)
  local ws = self.ws
  self.ws = nil
  self.buffer = ""
  if not ws then
    if onComplete then
      onComplete()
    end
    return
  end
  -- Use delete(), not Close(): delete() disconnects the socket AND frees its C4
  -- network binding (SetBindingAddress ""), then invokes onComplete once the
  -- module's deferred cleanup has run. The module allocates a fresh binding from
  -- the 6100-6199 pool on every WebSocket:new(), so the old binding MUST be
  -- fully released before the replacement is opened -- otherwise it is still
  -- held when the new one is allocated and leaks until the pool is exhausted and
  -- setupC4Connection asserts. openSocket therefore opens the new socket from
  -- inside this callback. (Mirrors control4-home-connect's Controller:connect.)
  local ok = pcall(function()
    ws:delete(onComplete)
  end)
  if not ok and onComplete then
    onComplete()
  end
end

-- Run the auth chain, then presign + open the socket.
function Connection:connectOnce()
  if self.stopped then
    return
  end
  log:debug("Hatch: connecting (auth + presign)")
  self.api:connect():next(function(result)
    if self.stopped then
      return
    end
    self.devices = result.devices or {}
    self.creds = result.creds
    self:openSocket(result.creds)
  end, function(err)
    local msg = type(err) == "table" and (err.error or JSON:encode(err)) or tostring(err)
    log:warn("Hatch: auth chain failed: %s", msg)
    self:scheduleReconnect()
  end)
end

function Connection:openSocket(creds)
  -- Release the previous socket's binding fully, THEN open the new one from the
  -- teardown callback. Opening before the old binding is freed strands it in the
  -- 6100-6199 pool (see teardownSocket).
  self:teardownSocket(function()
    if self.stopped then
      return
    end

    local url = SigV4.presignWssUrl(creds)
    log:debug("Hatch: opening WebSocket to AWS IoT")

    -- Arm the connect timeout BEFORE touching the WebSocket layer. If Start() (or
    -- WebSocket:new) throws or silently stalls -- as it can right after a
    -- controller reboot before the network subsystem is ready -- this timer is
    -- what gets us back into the reconnect backoff instead of hanging in
    -- "Connecting..." forever. Cancelled on MQTT CONNACK.
    self.connectTimer = SetTimer(self.connectTimer, CONNECT_TIMEOUT_MS, function()
      if not self.connected then
        log:warn("Hatch: WebSocket/MQTT handshake timed out; retrying")
        self:onWsClosed("connect timeout")
      end
    end)

    -- VERIFY_MODE none: C4's WebSocket TLS trust store does not include the AWS
    -- IoT ATS roots (same limitation home-connect documents). The presigned URL
    -- is the authenticator here, not the server cert. Wrapped in pcall so a throw
    -- from the WebSocket layer surfaces in the log and still retries (the timer).
    local ok, err = pcall(function()
      local ws = WebSocket:new(url, { "Sec-WebSocket-Protocol: mqtt" }, { VERIFY_MODE = "none" })
      if not ws then
        error("WebSocket:new returned nil")
      end
      self.ws = ws
      ws:SetEstablishedFunction(function()
        self:onWsEstablished()
      end)
      ws:SetProcessMessageFunction(function(_ws, data)
        self:onWsMessage(data)
      end)
      ws:SetClosedByRemoteFunction(function()
        self:onWsClosed("closed by remote")
      end)
      ws:SetOfflineFunction(function()
        self:onWsClosed("offline")
      end)
      ws:Start()
    end)
    if not ok then
      log:warn("Hatch: WebSocket open failed (%s); will retry", tostring(err))
    end
  end)

  self:scheduleRefresh(creds)
end

-- Refresh temporary creds (and the socket) shortly before they expire; AWS IoT
-- drops the session once the Cognito credentials lapse.
function Connection:scheduleRefresh(creds)
  local delay
  if creds and creds.expiration then
    delay = (creds.expiration - os.time()) * ONE_SECOND - REFRESH_MARGIN_MS
  end
  if not delay or delay < ONE_MINUTE then
    delay = 45 * ONE_MINUTE
  end
  self.refreshTimer = SetTimer(self.refreshTimer, delay, function()
    log:debug("Hatch: refreshing credentials")
    self:connectOnce()
  end)
end

-- ---- websocket callbacks -------------------------------------------------

function Connection:onWsEstablished()
  log:debug("Hatch: WS 101 established; sending MQTT CONNECT")
  self.buffer = ""
  local connect = MQTT.connect({
    clientId = self.clientId,
    keepAlive = KEEPALIVE_SECONDS,
    cleanSession = true,
  })
  self.ws:Send(connect, WS_BINARY)
end

function Connection:onWsMessage(data)
  self.buffer = self.buffer .. (data or "")
  while #self.buffer > 0 do
    local pkt, nextPos = MQTT.decode(self.buffer, 1)
    if not pkt then
      break -- incomplete; wait for more bytes
    end
    self.buffer = self.buffer:sub(nextPos)
    local ok, err = pcall(function()
      self:handlePacket(pkt)
    end)
    if not ok then
      log:warn("Hatch: error handling %s: %s", tostring(pkt.name), tostring(err))
    end
  end
end

function Connection:onWsClosed(reason)
  log:debug("Hatch: WebSocket closed (%s)", tostring(reason))
  self.connected = false
  CancelTimer(self.pingTimer)
  self.pingTimer = nil
  if self.onDisconnected then
    pcall(self.onDisconnected)
  end
  self:scheduleReconnect()
end

-- ---- MQTT ----------------------------------------------------------------

function Connection:sendMqtt(packet)
  if self.ws then
    self.ws:Send(packet, WS_BINARY)
  end
end

function Connection:handlePacket(pkt)
  if pkt.type == MQTT.CONNACK then
    if pkt.returnCode == 0 then
      log:info("Hatch: MQTT connected (CONNACK rc=0)")
      self.connected = true
      self.reconnectDelay = RECONNECT_MIN_MS
      CancelTimer(self.connectTimer)
      self.connectTimer = nil
      self:onMqttConnected()
    else
      log:warn("Hatch: MQTT CONNECT rejected (rc=%s)", tostring(pkt.returnCode))
      self:scheduleReconnect()
    end
  elseif pkt.type == MQTT.SUBACK then
    -- Subscription is now active, so it is safe to request current shadow state.
    local base = self.pendingGets and self.pendingGets[pkt.packetId]
    if base then
      self.pendingGets[pkt.packetId] = nil
      self:sendMqtt(MQTT.publish(base .. "/get", ""))
    end
  elseif pkt.type == MQTT.PUBLISH then
    self:onShadowMessage(pkt.topic, pkt.payload)
  end
  -- PINGRESP needs no action
end

function Connection:onMqttConnected()
  -- Subscribe to each device's shadow topics, then request current state only
  -- AFTER the SUBACK. AWS IoT delivers a shadow get/accepted only to active
  -- subscriptions, so publishing get before the SUBACK loses the response.
  self.pendingGets = {}
  for _, device in ipairs(self.devices) do
    local thing = device.thingName
    if thing then
      local base = SHADOW_PREFIX .. thing .. "/shadow"
      local packetId = self:nextPacketId()
      self.pendingGets[packetId] = base
      self:sendMqtt(MQTT.subscribe(packetId, {
        base .. "/update/accepted",
        base .. "/update/documents",
        base .. "/get/accepted",
        base .. "/get/rejected",
      }))
    end
  end

  self.pingTimer = SetTimer(self.pingTimer, PING_INTERVAL_MS, function()
    if self.connected and self.ws then
      self:sendMqtt(MQTT.pingReq())
    end
  end, true)

  if self.onConnected then
    pcall(self.onConnected, self.devices)
  end
end

function Connection:onShadowMessage(topic, payload)
  local thing = thingFromTopic(topic)
  if not thing or not payload or payload == "" then
    return
  end
  local ok, doc = pcall(function()
    return JSON:decode(payload)
  end)
  if not ok or type(doc) ~= "table" then
    return
  end

  -- update/accepted + get/accepted: { state = { reported, desired } }
  -- update/documents:               { current = { state = { reported } } }
  local state = doc.state or {}
  local reported = state.reported
  local desired = state.desired
  if not reported and doc.current and doc.current.state then
    reported = doc.current.state.reported
    desired = desired or doc.current.state.desired
  end

  if self.onShadow then
    pcall(self.onShadow, thing, reported, desired)
  end
end

-- ---- public control ------------------------------------------------------

--- Publish a desired-state patch for a device's shadow.
--- @param thingName string
--- @param desiredTable table the `state.desired` payload
--- @return boolean sent
function Connection:updateShadow(thingName, desiredTable)
  if not self.connected then
    return false
  end
  local topic = SHADOW_PREFIX .. thingName .. "/shadow/update"
  local doc = JSON:encode({ state = { desired = desiredTable } })
  self:sendMqtt(MQTT.publish(topic, doc))
  return true
end

--- Request a device's current shadow (response arrives via onShadow).
function Connection:getShadow(thingName)
  if self.connected then
    self:sendMqtt(MQTT.publish(SHADOW_PREFIX .. thingName .. "/shadow/get", ""))
  end
end

-- ---- reconnect -----------------------------------------------------------

function Connection:scheduleReconnect()
  if self.stopped then
    return
  end
  self.connected = false
  local delay = self.reconnectDelay
  self.reconnectDelay = math.min(self.reconnectDelay * 2, RECONNECT_MAX_MS)
  log:debug("Hatch: reconnecting in %dms", delay)
  self.reconnectTimer = SetTimer(self.reconnectTimer, delay, function()
    self:connectOnce()
  end)
end

return Connection

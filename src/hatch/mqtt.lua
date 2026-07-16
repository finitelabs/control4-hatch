-- Minimal MQTT 3.1.1 wire codec for AWS IoT over WebSocket binary frames.
--
-- Encodes the control packets the Hatch driver needs (CONNECT / PUBLISH /
-- SUBSCRIBE / PINGREQ / DISCONNECT) and decodes inbound packets (CONNACK /
-- SUBACK / PUBLISH / PINGRESP / PUBACK). QoS 0 throughout, which is all the
-- AWS IoT device-shadow topics require.

local MQTT = {}

-- Control packet type (high nibble of byte 1).
local CONNECT, CONNACK, PUBLISH, PUBACK, SUBSCRIBE, SUBACK, PINGREQ, PINGRESP, DISCONNECT =
  0x10, 0x20, 0x30, 0x40, 0x80, 0x90, 0xC0, 0xD0, 0xE0
MQTT.CONNACK, MQTT.PUBLISH, MQTT.SUBACK, MQTT.PINGRESP, MQTT.PUBACK = CONNACK, PUBLISH, SUBACK, PINGRESP, PUBACK

local function u16(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end

-- Length-prefixed UTF-8 string (MQTT "string").
local function mqttStr(s)
  return u16(#s) .. s
end

-- Variable-length "Remaining Length" field (7 bits/byte, high bit = continue).
local function encodeRemainingLength(n)
  local out = {}
  repeat
    local b = n % 128
    n = math.floor(n / 128)
    if n > 0 then
      b = bit.bor(b, 0x80)
    end
    out[#out + 1] = string.char(b)
  until n == 0
  return table.concat(out)
end

local function decodeRemainingLength(data, pos)
  local multiplier, value = 1, 0
  local b
  repeat
    b = data:byte(pos)
    if b == nil then
      return nil
    end
    pos = pos + 1
    value = value + bit.band(b, 0x7f) * multiplier
    multiplier = multiplier * 128
  until bit.band(b, 0x80) == 0
  return value, pos
end

--- CONNECT. opts = { clientId, keepAlive = 30, cleanSession = true, username, password }
function MQTT.connect(opts)
  local flags = 0
  if opts.cleanSession ~= false then
    flags = bit.bor(flags, 0x02)
  end
  if opts.username then
    flags = bit.bor(flags, 0x80)
  end
  if opts.password then
    flags = bit.bor(flags, 0x40)
  end

  local variableHeader = mqttStr("MQTT") .. string.char(0x04, flags) .. u16(opts.keepAlive or 30)
  local payload = mqttStr(opts.clientId or "")
  if opts.username then
    payload = payload .. mqttStr(opts.username)
  end
  if opts.password then
    payload = payload .. mqttStr(opts.password)
  end

  local remaining = variableHeader .. payload
  return string.char(CONNECT) .. encodeRemainingLength(#remaining) .. remaining
end

--- PUBLISH at QoS 0 (no packet id, fire and forget).
function MQTT.publish(topic, message)
  local remaining = mqttStr(topic) .. (message or "")
  return string.char(PUBLISH) .. encodeRemainingLength(#remaining) .. remaining
end

--- SUBSCRIBE at QoS 0. `topics` is a list of topic filter strings.
--- Fixed-header flags must be 0x02 for SUBSCRIBE per spec.
function MQTT.subscribe(packetId, topics)
  local filters = {}
  for _, topic in ipairs(topics) do
    filters[#filters + 1] = mqttStr(topic) .. string.char(0x00)
  end
  local remaining = u16(packetId) .. table.concat(filters)
  return string.char(bit.bor(SUBSCRIBE, 0x02)) .. encodeRemainingLength(#remaining) .. remaining
end

function MQTT.pingReq()
  return string.char(PINGREQ, 0x00)
end

function MQTT.disconnect()
  return string.char(DISCONNECT, 0x00)
end

--- Decode one packet from `data` at `pos` (default 1).
--- Returns (packet, nextPos), or nil if the buffer holds an incomplete packet.
function MQTT.decode(data, pos)
  pos = pos or 1
  if #data < pos + 1 then
    return nil
  end

  local byte1 = data:byte(pos)
  local packetType = bit.band(byte1, 0xf0)

  local remaining, bodyStart = decodeRemainingLength(data, pos + 1)
  if remaining == nil then
    return nil
  end
  local bodyEnd = bodyStart + remaining - 1
  if #data < bodyEnd then
    return nil -- incomplete; caller should buffer and retry
  end
  local nextPos = bodyEnd + 1

  local pkt = { type = packetType, flags = bit.band(byte1, 0x0f) }

  if packetType == CONNACK then
    pkt.name = "CONNACK"
    pkt.sessionPresent = bit.band(data:byte(bodyStart), 0x01)
    pkt.returnCode = data:byte(bodyStart + 1)
  elseif packetType == SUBACK then
    pkt.name = "SUBACK"
    pkt.packetId = data:byte(bodyStart) * 256 + data:byte(bodyStart + 1)
    pkt.returnCode = data:byte(bodyStart + 2)
  elseif packetType == PUBACK then
    pkt.name = "PUBACK"
    pkt.packetId = data:byte(bodyStart) * 256 + data:byte(bodyStart + 1)
  elseif packetType == PUBLISH then
    pkt.name = "PUBLISH"
    local topicLen = data:byte(bodyStart) * 256 + data:byte(bodyStart + 1)
    pkt.topic = data:sub(bodyStart + 2, bodyStart + 1 + topicLen)
    local p = bodyStart + 2 + topicLen
    local qos = bit.band(bit.rshift(byte1, 1), 0x03)
    if qos > 0 then
      pkt.packetId = data:byte(p) * 256 + data:byte(p + 1)
      p = p + 2
    end
    pkt.payload = data:sub(p, bodyEnd)
  elseif packetType == PINGRESP then
    pkt.name = "PINGRESP"
  else
    pkt.name = "UNKNOWN"
  end

  return pkt, nextPos
end

return MQTT

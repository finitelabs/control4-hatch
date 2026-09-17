-- Tests for MQTT.decode's Remaining Length bounds checks and the resync they
-- enable in Connection:onWsMessage.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_mqtt_decode.lua

local T = require("testlib")

require("c4_shim")

local MQTT = require("hatch.mqtt")
local Connection = require("hatch.connection")

--- A fixed header plus body, for Remaining Length < 128 (one length byte).
local function frame(byte1, body)
  return string.char(byte1, #body) .. body
end

local CONNACK, SUBACK, PUBACK, PUBLISH, PINGRESP = 0x20, 0x90, 0x40, 0x30, 0xD0

--------------------------------------------------------------------------------
T.section("Well-formed frames decode, including at the minimum Remaining Length")
--------------------------------------------------------------------------------

local pkt, nextPos = MQTT.decode(frame(CONNACK, "\0\0"), 1)
T.eq("CONNACK name", pkt and pkt.name, "CONNACK")
T.eq("CONNACK sessionPresent", pkt and pkt.sessionPresent, 0)
T.eq("CONNACK returnCode", pkt and pkt.returnCode, 0)
T.eq("CONNACK nextPos", nextPos, 5)

pkt, nextPos = MQTT.decode(frame(SUBACK, "\0\7\0"), 1)
T.eq("SUBACK name", pkt and pkt.name, "SUBACK")
T.eq("SUBACK packetId", pkt and pkt.packetId, 7)
T.eq("SUBACK returnCode", pkt and pkt.returnCode, 0)
T.eq("SUBACK nextPos", nextPos, 6)

pkt, nextPos = MQTT.decode(frame(PUBACK, "\1\2"), 1)
T.eq("PUBACK name", pkt and pkt.name, "PUBACK")
T.eq("PUBACK packetId", pkt and pkt.packetId, 258)
T.eq("PUBACK nextPos", nextPos, 5)

-- Remaining Length is exactly 2 + topicLen, so the payload is empty. A guard
-- written with <= instead of < refuses this.
pkt, nextPos = MQTT.decode(frame(PUBLISH, "\0\4abcd"), 1)
T.eq("PUBLISH topic", pkt and pkt.topic, "abcd")
T.eq("PUBLISH empty payload", pkt and pkt.payload, "")
T.eq("PUBLISH nextPos", nextPos, 9)

pkt, nextPos = MQTT.decode(frame(PUBLISH, "\0\4abcdhello"), 1)
T.eq("PUBLISH topic with payload", pkt and pkt.topic, "abcd")
T.eq("PUBLISH payload", pkt and pkt.payload, "hello")

-- QoS 1 (fixed-header bit 1) puts a packet id between topic and payload.
pkt = MQTT.decode(frame(PUBLISH + 0x02, "\0\4abcd\0\9hi"), 1)
T.eq("PUBLISH qos1 topic", pkt and pkt.topic, "abcd")
T.eq("PUBLISH qos1 packetId", pkt and pkt.packetId, 9)
T.eq("PUBLISH qos1 payload", pkt and pkt.payload, "hi")

pkt, nextPos = MQTT.decode(frame(PINGRESP, ""), 1)
T.eq("PINGRESP name", pkt and pkt.name, "PINGRESP")
T.eq("PINGRESP nextPos", nextPos, 3)

--------------------------------------------------------------------------------
T.section("A Remaining Length too short for the packet type is refused, not raised")
--------------------------------------------------------------------------------

--- decode must return (nil, nextPos): no raise, no packet, and the boundary the
--- declared Remaining Length fixes, so the caller can skip exactly this frame.
--- `ok` is a conjunct of every assertion rather than a guard around them: a raise
--- has to fail the case, not skip it.
local function refuses(name, data, wantNextPos)
  local ok, got, pos = pcall(MQTT.decode, data, 1)
  T.check(name .. ": does not raise", ok, tostring(got))
  T.check(name .. ": returns no packet", ok and got == nil, "got " .. T.show(got))
  T.check(name .. ": reports the frame boundary", ok and pos == wantNextPos, "got " .. tostring(pos))
end

-- Raising sites named by the DRV-122 audit.
refuses("CONNACK with Remaining Length 0", frame(CONNACK, ""), 3)
refuses("SUBACK with Remaining Length 1", frame(SUBACK, "\0"), 4)
refuses("PUBACK with Remaining Length 1", frame(PUBACK, "\0"), 4)
refuses("PUBLISH with Remaining Length 0", frame(PUBLISH, ""), 3)
refuses("PUBLISH with Remaining Length 1", frame(PUBLISH, "\0"), 4)

-- Short by one of the fields the branch reads. These never raised; they decoded
-- a nil field, which reads downstream as a rejected CONNACK or a failed SUBACK.
refuses("CONNACK with Remaining Length 1", frame(CONNACK, "\0"), 4)
refuses("SUBACK with Remaining Length 2", frame(SUBACK, "\0\7"), 5)

-- A topic length that runs past the frame: decode used to return a topic built
-- from the following packet's bytes.
refuses("PUBLISH with topicLen past the frame", frame(PUBLISH, "\0\100ab"), 7)
refuses("PUBLISH qos1 with no room for the packet id", frame(PUBLISH + 0x02, "\0\4abcd\0"), 10)

--------------------------------------------------------------------------------
T.section("An incomplete frame is still buffered, not skipped")
--------------------------------------------------------------------------------

-- Distinct from malformed: the body has not arrived yet, so there is no boundary
-- to resync on and the caller must wait rather than discard.
local got, pos = MQTT.decode(string.char(PUBLISH, 10) .. "\0\4abc", 1)
T.eq("partial PUBLISH returns no packet", got, nil)
T.eq("partial PUBLISH returns no boundary", pos, nil)

got, pos = MQTT.decode(string.char(CONNACK), 1)
T.eq("bare fixed-header byte returns no packet", got, nil)
T.eq("bare fixed-header byte returns no boundary", pos, nil)

--------------------------------------------------------------------------------
T.section("Connection:onWsMessage drops a malformed frame and keeps reading")
--------------------------------------------------------------------------------

local SHADOW_TOPIC = "$aws/things/thing-1/shadow/update/accepted"
local goodPublish = MQTT.publish(SHADOW_TOPIC, '{"state":{"reported":{"volume":42}}}')

local function newConnection()
  local seen = {}
  local conn = Connection:new({
    api = {},
    onShadow = function(thing, reported)
      seen[#seen + 1] = { thing = thing, reported = reported }
    end,
  })
  conn.buffer = ""
  return conn, seen
end

local function feed(name, bytes)
  local conn, seen = newConnection()
  local ok, err = pcall(function()
    conn:onWsMessage(bytes)
  end)
  T.check(name .. ": does not raise", ok, tostring(err))
  return conn, seen, ok
end

local conn, seen, ok = feed("malformed CONNACK then a shadow PUBLISH", frame(CONNACK, "") .. goodPublish)
T.check("the following PUBLISH is still delivered", ok and #seen == 1, "delivered " .. tostring(#seen))
T.check("delivered for the right thing", ok and seen[1] and seen[1].thing == "thing-1", T.show(seen[1]))
T.check("buffer fully drained", ok and conn.buffer == "", "left " .. tostring(conn and #conn.buffer) .. " bytes")

conn, seen, ok = feed("malformed PUBLISH then a shadow PUBLISH", frame(PUBLISH, "\0") .. goodPublish)
T.check("the following PUBLISH is still delivered (2)", ok and #seen == 1, "delivered " .. tostring(#seen))
T.check("buffer fully drained (2)", ok and conn.buffer == "", "left " .. tostring(conn and #conn.buffer) .. " bytes")

-- The wedge itself: a malformed frame arriving alone must leave the buffer empty,
-- or every later frame re-decodes these same bytes and the driver goes deaf with
-- the socket still up.
conn, seen, ok = feed("malformed PUBLISH alone", frame(PUBLISH, "\0"))
T.check("malformed frame is consumed", ok and conn.buffer == "", "left " .. tostring(conn and #conn.buffer) .. " bytes")

conn, seen, ok = feed("malformed PUBLISH, then a later good frame", frame(PUBLISH, "\0"))
if ok then
  conn:onWsMessage(goodPublish)
end
T.check("a frame arriving after the wedge is delivered", ok and #seen == 1, "delivered " .. tostring(#seen))

-- An incomplete frame must NOT be dropped: the rest arrives on a later callback.
conn, seen, ok = feed("split PUBLISH, first half", goodPublish:sub(1, 12))
T.check(
  "incomplete frame is retained",
  ok and conn.buffer == goodPublish:sub(1, 12),
  "buffer " .. T.show(conn and conn.buffer)
)
if ok then
  conn:onWsMessage(goodPublish:sub(13))
end
T.check("reassembled frame is delivered", ok and #seen == 1, "delivered " .. tostring(#seen))

T.finish()

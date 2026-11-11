-- A device's shadow reports, as AWS sends them for a Hatch Rest+: get/accepted and update/documents carry the whole
-- reported document, update/accepted only the fields that changed. Each report reaches the account driver whole.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_shadow_reports.lua

local T = require("testlib")

require("c4_shim")

local JSON = require("JSON")
local Connection = require("hatch.connection")
local Device = require("hatch.device")

local THING = "thing-hallie"
local BASE = "$aws/things/" .. THING .. "/shadow/"

local seen = {}
local connection = Connection:new({
  onShadow = function(thing, reported)
    seen[#seen + 1] = { thing = thing, state = reported and Device.parseState(reported) }
  end,
})

--- Deliver a shadow message, and return what the account driver was handed, or nil for nothing.
local function deliver(kind, doc)
  local before = #seen
  connection:onShadowMessage(BASE .. kind, JSON:encode(doc))
  return #seen > before and seen[#seen].state or nil
end

-- A lit night light at about half brightness in blue, as dev's Hatch reported it (2026-11-11).
local function whole(color)
  return {
    connected = true,
    current = {
      playing = "remote",
      srId = 0,
      step = 0,
      sound = { id = 19998, v = 0 },
      color = color,
    },
  }
end
local BLUE = { id = 9999, r = 0, g = 0, b = 65535, i = 32767, w = 0 }

T.section("A partial report before any whole one is held back")
T.eq(
  "nothing is handed on",
  deliver("update/accepted", { state = { reported = { current = { color = { i = 65535 } } } } }),
  nil
)

T.section("A whole report is handed on as it is")
local state = deliver("get/accepted", { state = { reported = whole(BLUE) } })
T.eq("lit", state.lightOn, true)
T.eq("at half", state.brightnessPct, 50)

T.section("A partial report keeps what it leaves out")
-- A new color with no id, as update/accepted reported a preset (dev, 2026-11-11).
state = deliver("update/accepted", { state = { reported = { current = { color = { r = 0, g = 65535, b = 52428 } } } } })
T.eq("still lit", state.lightOn, true)
T.eq("still at half", state.brightnessPct, 50)
T.eq("in the new color", { state.red, state.green, state.blue }, { 0, 255, 204 })
-- A brightness with no id or color, as update/accepted reported a level.
state = deliver("update/accepted", { state = { reported = { current = { color = { i = 65535 } } } } })
T.eq("lit at full", { state.lightOn, state.brightnessPct }, { true, 100 })
T.eq("in the color before", state.green, 255)
-- Nothing reported: the accepted echo of a desired update alone.
T.eq("an echo with nothing reported hands on no state", deliver("update/accepted", { state = { desired = {} } }), nil)

T.section("An off that a partial report carries is still an off")
state =
  deliver("update/accepted", { state = { reported = { current = { color = { id = 9998, r = 0, g = 0, b = 0 } } } } })
T.eq("off", state.lightOn, false)

T.section("A whole report replaces what partial ones built")
state = deliver("update/documents", { current = { state = { reported = whole(BLUE) } } })
T.eq("lit in blue at half", { state.lightOn, state.blue, state.brightnessPct }, { true, 255, 50 })

T.section("Each device keeps its own document")
T.eq(
  "a partial report for another device with no whole one is held back",
  (function()
    local before = #seen
    connection:onShadowMessage(
      "$aws/things/thing-asa/shadow/update/accepted",
      JSON:encode({ state = { reported = { current = { color = { i = 0 } } } } })
    )
    return #seen - before
  end)(),
  0
)

T.finish()

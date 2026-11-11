-- The Hatch lights' adapters on the wire: what each puts in an ENTITY_COMMAND for a library command,
-- and what each makes of the coordinator's UPDATE_STATE and UPDATE_DISCONNECT. What the proxy is told
-- is the library's, proved by test/test_light_contract.lua.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_hatch_adapters.lua

local T = require("testlib")

require("c4_shim")
require("light_rigs") -- Control4's RGB converters and the driver config the drivers read

local D = require("light_drivers")
local F = require("c4_fixtures")
local Light = require("lib.light")

local COORD = 5002

Properties["Driver Status"] = ""

local sent = {}
local prior = C4.SendToProxy
C4.SendToProxy = function(self, id, cmd, params, ...)
  if id == COORD then
    sent[#sent + 1] = cmd == "ENTITY_COMMAND" and DeserializeSafe(params.body) or cmd
    return
  end
  return prior(self, id, cmd, params, ...)
end

--- Load a driver and record what its adapter hands the light. `heard.kind` is the level verdict's
--- kind the light answers each report with.
local function load(folder)
  F.dofileBuild(D.root() .. "/drivers/" .. folder .. "/driver.lua", "oss")
  local light = Light.made[#Light.made]
  local heard = { reports = {}, lost = {}, kind = "own" }
  function light:report(state)
    heard.reports[#heard.reports + 1] = state
    return { level = { kind = heard.kind } }
  end
  function light:lost(kind)
    heard.lost[#heard.lost + 1] = kind or {}
  end
  function light:declare() end
  return light, heard
end

local function send(light, cmd)
  sent = {}
  light.adapter:send(cmd)
  return sent
end

local function push(state, favorites)
  ReceivedFromProxy(
    COORD,
    "UPDATE_STATE",
    { state = SerializeSafe(state), favorites = favorites and SerializeSafe(favorites) or nil }
  )
end

local RED = { x = 0.6, y = 0.32, mode = 0 }

T.section("hatch_light: each command goes out as the coordinator takes it")
do
  local light = load("hatch_light")
  T.eq("an off", send(light, { on = false }), { { command = "off" } })
  T.eq("a level", send(light, { on = true, level = 0.5 }), { { command = "setBrightness", brightness = 50 } })
  T.eq("a level never rounds to 0, which would be an off", send(light, { on = true, level = 0.004 })[1].brightness, 1)
  local red, green, blue = C4:ColorXYtoRGB(RED.x, RED.y)
  local rgb = { math.floor(red + 0.5), math.floor(green + 0.5), math.floor(blue + 0.5) }
  local withColor = send(light, { on = true, level = 1, color = RED })[1]
  T.eq("a level with a color carries its RGB", { withColor.red, withColor.green, withColor.blue }, rgb)
  local lit = send(light, { on = true, color = RED })[1]
  T.eq("a color alone while on goes as an on with its RGB", { lit.command, lit.red }, { "on", rgb[1] })
  local x, y = C4:ColorRGBtoXY(rgb[1], rgb[2], rgb[3])
  local shown = light.adapter:shows(RED)
  T.eq("shows: the nearest color the night light makes in RGB", { shown.x, shown.y, shown.mode }, { x, y, 0 })
end

T.section("hatch_light: a color sent while off is kept for the next on, until the light is lit elsewhere")
do
  local light, heard = load("hatch_light")
  T.eq("a color for an off light sends nothing", send(light, { on = false, color = RED }), {})
  local on = send(light, { on = true, level = 1 })[1]
  T.check("the next on carries it", on.red ~= nil, on)
  T.eq("and the on after carries none", send(light, { on = true, level = 1 })[1].red, nil)
  local LIT = { online = true, on = true, red = 255, green = 255, blue = 255, brightnessPct = 50 }
  send(light, { on = false, color = RED })
  heard.kind = "history"
  push(LIT)
  T.check(
    "a lit report from before the Off keeps it",
    send(light, { on = true, level = 1 })[1].red ~= nil,
    "the cloud's late push dropped the held color"
  )
  send(light, { on = false, color = RED })
  heard.kind = "hand"
  push(LIT)
  T.eq("a light lit by another hand has had its next on", send(light, { on = true, level = 1 })[1].red, nil)
end

T.section("hatch_light: the coordinator's state becomes the light's reports")
do
  local _, heard = load("hatch_light")
  push({ online = true, on = true, red = 255, green = 0, blue = 0, brightnessPct = 70 })
  local report = heard.reports[#heard.reports]
  T.eq("a lit light: on and its level", { report.on, report.level }, { true, 0.7 })
  T.check("and its color", report.color ~= nil and report.color.x > 0.5, report.color)
  push({ online = true, on = false, red = 0, green = 0, blue = 0, brightnessPct = 70 })
  report = heard.reports[#heard.reports]
  T.eq("an off light: off, the level it keeps, and no color", { report.on, report.level, report.color }, { false, 0.7 })
  push({ online = false })
  T.eq("a device the cloud says is offline is lost", heard.lost[#heard.lost], {})
  ReceivedFromProxy(COORD, "UPDATE_DISCONNECT", { suspended = "true" })
  T.eq("the account's own stop is a suspend", heard.lost[#heard.lost], { suspended = true })
  ReceivedFromProxy(COORD, "UPDATE_DISCONNECT", {})
  T.eq("a lost link to Hatch is a loss", heard.lost[#heard.lost], { suspended = false })
end

T.section("hatch_volume: a level while stopped starts the installer's choice, and one while playing sets the volume")
do
  local light, heard = load("hatch_volume")
  T.eq("an off is a stop", send(light, { on = false }), { { command = "off" } })
  T.eq(
    "stopped, with nothing to play chosen, a level resumes the last sound at it",
    send(light, { on = true, level = 0.6 }),
    { { command = "on", brightness = 60 } }
  )
  push({ online = true, on = false, brightnessPct = 40 }, { { id = "f1", name = "Bedtime" } })
  T.eq(
    "stopped, a level starts the first favorite, which brings its own volume",
    send(light, { on = true, level = 0.6 }),
    { { command = "on", favoriteId = "f1" } }
  )
  push({ online = true, on = true, brightnessPct = 40 })
  T.eq("playing, a level sets the volume", send(light, { on = true, level = 0.3 }), {
    { command = "setBrightness", brightness = 30 },
  })
  local report = heard.reports[#heard.reports]
  T.eq("its state is reported as on and the volume", { report.on, report.level }, { true, 0.4 })
end

T.finish()

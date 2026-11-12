-- The Night Light's and the Volume's adapters (src/hatch/light_adapter.lua, src/hatch/volume_adapter.lua) on their
-- own: each light library command as the ENTITY_COMMAND the account takes, and each state the account tells as the
-- report the library reads, with what was sent read back as that command's values.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_hatch_adapters.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local Color = require("lib.light.color")
local LightAdapter = require("hatch.light_adapter")
local VolumeAdapter = require("hatch.volume_adapter")

--- A color from its channels, 0-1.
local function rgb(r, g, b)
  local x, y = Color.rgbToXY(r, g, b)
  return { x = x, y = y, mode = "xy" }
end
local RED, BLUE = rgb(1, 0, 0), rgb(0, 0, 1)

--- A command with every field, the rest as given.
local function command(over)
  local cmd = {
    kind = "change",
    on = true,
    fromOff = false,
    level = 1,
    color = nil,
    setsLevel = false,
    setsColor = false,
    transitionMs = 0,
    from = { level = 1 },
    colorUnchosen = false,
  }
  for k, v in pairs(over) do
    cmd[k] = v
  end
  return cmd
end

-- ─── The Night Light ───────────────────────────────────────────────────────

local bodies, asked = {}, 0
local light = LightAdapter:new({
  send = function(body)
    bodies[#bodies + 1] = body
  end,
  refresh = function()
    asked = asked + 1
  end,
})

--- What a command sent, and what it returned.
local function sent(adapter, over)
  local rest = adapter:send(command(over))
  return bodies[#bodies], rest
end

T.section("the night light: an on from off comes on in its color at its level, in one command")
T.eq(
  "on at half in red",
  sent(light, { fromOff = true, level = 0.5, color = RED, setsLevel = true, setsColor = true }),
  { command = "on", red = 255, green = 0, blue = 0, brightness = 50 }
)
T.eq(
  "an On that resumes still carries the level, so the account's last word is never used",
  sent(light, { fromOff = true, level = 0.3, color = RED, setsColor = true }),
  { command = "on", red = 255, green = 0, blue = 0, brightness = 30 }
)

T.section("the night light: a change while lit carries both color and brightness")
T.eq(
  "a color goes at the level it carries",
  sent(light, { level = 1, color = BLUE, setsColor = true }),
  { command = "setColor", red = 0, green = 0, blue = 255, brightness = 100 }
)
T.eq("the lowest level is 1 %", sent(light, { level = 0.001, color = BLUE, setsLevel = true }).brightness, 1)

T.section("the night light: an off is an off")
T.eq("off", sent(light, { on = false, level = 0.5, color = BLUE }), { command = "off" })

T.section("the night light: a report of what was sent is that command's level and color")
sent(light, { fromOff = true, level = 0.5, color = RED, setsLevel = true, setsColor = true })
local report = light:report({ online = true, on = true, red = 255, green = 0, blue = 1, brightnessPct = 50 })
T.eq("lit at half", { report.kind, report.on, report.level }, { "push", true, 0.5 })
T.truthy("in the color sent", report.color == RED)
report = light:report({ online = true, on = false, red = 255, green = 0, blue = 0, brightnessPct = 50 })
T.eq("off, the account still tells the level and color it keeps", { report.on, report.level }, { false, 0.5 })
T.truthy("in the color sent", report.color == RED)

T.section("the night light: a report of another color and level")
report = light:report({ online = true, on = true, red = 0, green = 0, blue = 255, brightnessPct = 30 })
T.eq("at its level", report.level, 0.3)
T.eq("in its color", { report.color.mode, round(report.color.x, 3), round(report.color.y, 3) }, {
  "xy",
  round(BLUE.x, 3),
  round(BLUE.y, 3),
})
T.eq(
  "black and no brightness carry neither",
  light:report({ online = true, on = false, red = 0, green = 0, blue = 0, brightnessPct = 0 }),
  { kind = "push", on = false }
)

T.section("the night light: refresh asks the account")
light:refresh()
T.eq("once", asked, 1)

T.section("the night light's facts")
T.eq("a color set while off waits for the next on", LightAdapter.DEVICE.colorWhileOff, "hold")
T.eq("in 1 % steps", LightAdapter.DEVICE.levelSteps, 100)
T.eq("no fades", LightAdapter.DEVICE.fade, { kind = "own", own = { onMs = 0, offMs = 0, changeMs = 0 } })
T.eq("the account's 5 s", LightAdapter.DEVICE.feedback, { shows = "target", waitMs = 5000, refresh = true })

-- ─── The Volume ────────────────────────────────────────────────────────────

local target = nil
local volume = VolumeAdapter:new({
  send = function(body)
    bodies[#bodies + 1] = body
  end,
  refresh = function()
    asked = asked + 1
  end,
  target = function()
    return target
  end,
})

T.section("the volume: a level while playing sets the volume")
local body, rest = sent(volume, { level = 0.4, setsLevel = true })
T.eq("a volume", body, { command = "setBrightness", brightness = 40 })
T.eq("and no rest", rest, nil)
T.eq("ON while playing is a volume set too, so play continues", sent(volume, { level = 0.4 }), {
  command = "setBrightness",
  brightness = 40,
})

T.section("the volume: an on from off starts what Turn On Plays names")
target = { soundId = 7 }
T.eq("a sound, at the level", sent(volume, { fromOff = true, level = 0.4 }), {
  command = "on",
  soundId = 7,
  brightness = 40,
})
target = nil
T.eq("nothing chosen: the last sound, at the level", sent(volume, { fromOff = true, level = 0.4 }), {
  command = "on",
  brightness = 40,
})

T.section("the volume: a favorite applies its own volume, told as the command goes out")
target = { favoriteId = 3, favorite = { steps = { { sound = { v = 13107 } } } } }
body, rest = sent(volume, { fromOff = true, level = 0.4 })
T.eq("the favorite, with no volume of the light's", body, { command = "on", favoriteId = 3 })
T.eq("rests at the favorite's volume", rest, { level = 0.2 })
report = volume:report({ online = true, on = true, brightnessPct = 20 })
T.eq("and its report is that level", { report.on, report.level }, { true, 0.2 })
target = { favoriteId = 4, favorite = { steps = {} } }
body, rest = sent(volume, { fromOff = true, level = 0.4 })
T.eq("a favorite whose volume is unknown rests nowhere", { body, rest }, { { command = "on", favoriteId = 4 } })

T.section("the volume: an off stops, and a stopped report keeps the volume")
T.eq("off", sent(volume, { on = false, level = 0.4 }), { command = "off" })
report = volume:report({ online = true, on = false, brightnessPct = 35 })
T.eq("stopped at 35", { report.kind, report.on, report.level }, { "push", false, 0.35 })
T.eq(
  "no volume carries none",
  volume:report({ online = true, on = false, brightnessPct = 0 }),
  { kind = "push", on = false }
)

T.section("the volume's facts")
T.eq("a dimmer with no color", { VolumeAdapter.DEVICE.dims, VolumeAdapter.DEVICE.color }, { true, false })
T.eq("the account's 5 s", VolumeAdapter.DEVICE.feedback, { shows = "target", waitMs = 5000, refresh = true })

T.finish()

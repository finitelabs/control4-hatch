-- The Hatch light companions' rigs for the conformance run (test/test_light_conformance.lua): each driver as it
-- ships, bound to a fake Hatch account that keeps one device as Hatch does. It takes each ENTITY_COMMAND and tells
-- the companion the device's state a second later, as the account does once Hatch's cloud answers, and answers a
-- REFRESH_STATE the same way.

local C = require("light_conformance")
local D = require("light_drivers")
local F = require("c4_fixtures")
local Light = require("lib.light")
local Color = require("lib.light.color")
local Favorites = require("hatch.favorites")

local COORD = 5002
local ANSWER_MS = 1000

local WHITE = { x = 0.3127, y = 0.329 }

--- Route the companion's sends to the account to `take`, and pass every send on.
--- @param take fun(cmd: string, body: table)
local function account(take)
  local prior = C4.SendToProxy
  C4.SendToProxy = function(self, id, cmd, params, ...)
    if id == COORD then
      take(cmd, cmd == "ENTITY_COMMAND" and DeserializeSafe(params.body) or {})
    end
    return prior(self, id, cmd, params, ...)
  end
end

--- @param tParams table
local function tell(tParams)
  ReceivedFromProxy(COORD, "UPDATE_STATE", tParams)
end

-- ─── The Night Light ───────────────────────────────────────────────────────

--- @type LightRig
local nightLight = { name = "hatch_light", folder = "hatch_light" }

--- Load the Night Light afresh, over an account whose night light is in `state`, and run its init.
--- @param h LightRigHarness
--- @param state LightValues|nil
--- @return LightRigDevice
function nightLight.load(h, state)
  state = state or { on = false, level = 1, color = WHITE }
  -- The night light keeps its color and brightness while off, and reports black and 0 then.
  local device = { on = state.on == true, pct = round((state.level or 1) * 100), color = state.color or WHITE }
  local linked = true

  local function push()
    if not linked then
      return
    end
    local red, green, blue, pct = 0, 0, 0, 0
    if device.on then
      local r, g, b = Color.xyToRGB(device.color.x, device.color.y)
      red, green, blue, pct = round(r * 255), round(g * 255), round(b * 255), device.pct
    end
    tell({
      state = SerializeSafe({
        online = true,
        on = device.on,
        red = red,
        green = green,
        blue = blue,
        brightnessPct = pct,
      }),
    })
  end

  account(function(cmd, body)
    if not linked then
      return
    elseif cmd == "REFRESH_STATE" then
      h.clock.at(ANSWER_MS, push)
      return
    elseif cmd ~= "ENTITY_COMMAND" then
      return
    end
    if body.command == "off" then
      device.on = false
    elseif body.command == "on" or body.command == "setColor" then
      device.on = true
      local top = math.max(body.red or 0, body.green or 0, body.blue or 0)
      if top > 0 then
        local x, y = Color.rgbToXY(body.red / top, body.green / top, body.blue / top)
        device.color = { x = x, y = y }
      end
      device.pct = tonumber(body.brightness) or device.pct
    end
    h.clock.at(ANSWER_MS, push)
  end)

  F.dofileBuild(D.path(D.root(), "hatch_light"), "oss")
  h.light = Light.made[#Light.made]
  OnDriverInit()
  OnDriverLateInit()

  return {
    state = function()
      return {
        on = device.on,
        level = device.pct / 100,
        color = { x = device.color.x, y = device.color.y, mode = "xy" },
      }
    end,
    -- The account tells the whole state with every change, so a quiet change reports like any other.
    set = function(change)
      if change.on ~= nil then
        device.on = change.on
      end
      if change.level then
        device.pct = round(change.level * 100)
      end
      if change.color and change.color.x then
        device.color = { x = change.color.x, y = change.color.y }
      end
      push()
    end,
    drop = function()
      linked = false
      ReceivedFromProxy(COORD, "UPDATE_DISCONNECT", {})
    end,
    back = function()
      linked = true
      push()
    end,
    suspend = function()
      linked = false
      ReceivedFromProxy(COORD, "UPDATE_DISCONNECT", { suspended = true })
    end,
    resume = function()
      linked = true
      push()
    end,
  }
end

-- ─── The Volume ────────────────────────────────────────────────────────────

local SOUNDS = { { id = 7, title = "Rain" } }
-- Bedtime applies a volume of 20 % (13107 of 65535).
local FAVORITES = { { id = 3, name = "Bedtime", steps = { { sound = { v = 13107 } } } } }

--- @type LightRig
local volume = { name = "hatch_volume", folder = "hatch_volume" }

--- Load the Volume afresh, over an account whose sound machine is in `state`, with Turn On Plays naming a sound,
--- and run its init.
--- @param h LightRigHarness
--- @param state LightValues|nil
--- @return LightRigDevice
function volume.load(h, state)
  state = state or { on = false, level = 0.35 }
  local device = { playing = state.on == true, pct = round((state.level or 0.35) * 100) }
  local linked = true

  local function push()
    if not linked then
      return
    end
    tell({
      sounds = SerializeSafe(SOUNDS),
      favorites = SerializeSafe(FAVORITES),
      state = SerializeSafe({ online = true, on = device.playing, brightnessPct = device.pct }),
    })
  end

  account(function(cmd, body)
    if not linked then
      return
    elseif cmd == "REFRESH_STATE" then
      h.clock.at(ANSWER_MS, push)
      return
    elseif cmd ~= "ENTITY_COMMAND" then
      return
    end
    if body.command == "off" then
      device.playing = false
    elseif body.command == "on" then
      device.playing = true
      if body.favoriteId then
        for _, favorite in ipairs(FAVORITES) do
          if favorite.id == body.favoriteId then
            device.pct = Favorites.volumePct(favorite) or device.pct
          end
        end
      elseif tonumber(body.brightness) then
        device.pct = tonumber(body.brightness)
      end
    elseif body.command == "setBrightness" then
      device.pct = tonumber(body.brightness) or device.pct
    end
    h.clock.at(ANSWER_MS, push)
  end)

  Properties["Turn On Plays"] = "Sound: Rain"
  F.dofileBuild(D.path(D.root(), "hatch_volume"), "oss")
  h.light = Light.made[#Light.made]
  OnDriverInit()
  OnDriverLateInit()

  return {
    state = function()
      return { on = device.playing, level = device.pct / 100 }
    end,
    set = function(change)
      if change.on ~= nil then
        device.playing = change.on
      end
      if change.level then
        device.pct = round(change.level * 100)
      end
      push()
    end,
    drop = function()
      linked = false
      ReceivedFromProxy(COORD, "UPDATE_DISCONNECT", {})
    end,
    back = function()
      linked = true
      push()
    end,
    suspend = function()
      linked = false
      ReceivedFromProxy(COORD, "UPDATE_DISCONNECT", { suspended = true })
    end,
    resume = function()
      linked = true
      push()
    end,
  }
end

--- A favorite applies its own volume, which the light is told as the command goes out.
--- @param h LightRigHarness
function volume.rest(h)
  Properties["Turn On Plays"] = "Favorite: Bedtime"
  h.proxy:send("ON")
end

return { version = C.RIG_VERSION, rigs = { hatch_light = { nightLight }, hatch_volume = { volume } } }

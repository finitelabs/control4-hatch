--- The Hatch Night Light's adapter for the light library (lib.light): one Hatch's night light, through the account.
---
--- The light owns no cloud link. It binds to the Hatch account's light connection, which tells it the device's
--- state as UPDATE_STATE and takes its commands as ENTITY_COMMAND. Color crosses as RGB 0-255 and brightness as a
--- percentage. The account sets the light's color and brightness together, so every lit command carries both.
---
--- The adapter keeps the color and brightness it last sent, so the account's answer is read as the command's own
--- values. It keeps them from that send until the next one, or until the driver calls forget() with light:lost or
--- light:reset. A report after those is read as the account tells it.

require("lib.utils")

local Color = require("lib.light.color")

--- The night light's facts. It cannot take a color without lighting, so a color set while it is off waits for
--- the next on. A command reaches it through Hatch's cloud, and the account tells its state again within 5 s.
--- @type LightDevice
local DEVICE = {
  dims = true,
  color = true,
  colorWhileOff = "hold",
  levelSteps = 100,
  fade = { kind = "own", own = { onMs = 0, offMs = 0, changeMs = 0 } },
  feedback = { shows = "target", waitMs = 5000, refresh = true },
}

--- The color and brightness last sent, and the level and color of the command they were for.
--- @class HatchLightWire
--- @field red integer
--- @field green integer
--- @field blue integer
--- @field pct integer
--- @field level number
--- @field color LightColor

--- @class HatchLightOptions
--- @field send fun(body: table) Sends an ENTITY_COMMAND body to the account.
--- @field refresh fun() Asks the account for the device's state.

--- @class HatchLight : LightAdapter
--- @field sendBody fun(body: table)
--- @field ask fun()
--- @field wire HatchLightWire|nil
local Adapter = {}
Adapter.__index = Adapter
Adapter.DEVICE = DEVICE

--- @param opts HatchLightOptions
--- @return HatchLight
function Adapter:new(opts)
  local instance = setmetatable({}, self)
  instance.sendBody = opts.send
  instance.ask = opts.refresh
  instance.wire = nil
  return instance
end

--- A channel, 0-1, as a byte.
--- @param v number|nil
--- @return integer
local function byte(v)
  return InRange(round((tofinite(v) or 0) * 255), 0, 255)
end

--- Whether a reported channel is within one of the one sent.
--- @param sent integer
--- @param reported number|nil
--- @return boolean
local function near(sent, reported)
  return reported ~= nil and math.abs(sent - reported) <= 1
end

--- Puts a command on the wire: an off, or the color and brightness the light comes on in or changes to. The light
--- takes no color while off, so a command that leaves it off sends nothing.
--- @param cmd LightCommand
--- @return nil
function Adapter:send(cmd)
  if not cmd.on then
    if cmd.setsLevel then
      self.sendBody({ command = "off" })
    end
    return
  end
  local r, g, b = Color.xyToRGB(cmd.color.x, cmd.color.y)
  local wire = {
    red = byte(r),
    green = byte(g),
    blue = byte(b),
    pct = InRange(round(cmd.level * 100), 1, 100),
    level = cmd.level,
    color = cmd.color,
  }
  self.wire = wire
  self.sendBody({
    command = cmd.fromOff and "on" or "setColor",
    red = wire.red,
    green = wire.green,
    blue = wire.blue,
    brightness = wire.pct,
  })
end

function Adapter:refresh()
  self.ask()
end

--- Forgets the color and brightness last sent. The driver calls it with light:lost and light:reset.
function Adapter:forget()
  self.wire = nil
end

--- No device page.
function Adapter:show(_) end

--- The light's state as the account told it. A brightness or color the last command sent is that command's
--- level or color.
--- @param state table { on, red, green, blue, brightnessPct }
--- @return LightReport
function Adapter:report(state)
  local report = { kind = "push", on = state.on == true }
  local wire = self.wire
  local pct = tofinite(state.brightnessPct)
  if pct and pct > 0 then
    report.level = (wire and pct == wire.pct) and wire.level or InRange(pct, 0, 100) / 100
  end
  local r, g, b = tofinite(state.red), tofinite(state.green), tofinite(state.blue)
  if r and g and b and (r > 0 or g > 0 or b > 0) then
    if wire and near(wire.red, r) and near(wire.green, g) and near(wire.blue, b) then
      report.color = wire.color
    else
      local x, y = Color.rgbToXY(InRange(r, 0, 255) / 255, InRange(g, 0, 255) / 255, InRange(b, 0, 255) / 255)
      report.color = { x = x, y = y, mode = "xy" }
    end
  end
  return report
end

return Adapter

--- The Hatch Volume's adapter for the light library (lib.light): one Hatch's sound volume as a dimmer, through the
--- account.
---
--- On plays what Turn On Plays names, off stops, and a level while playing sets the volume. A sound starts at the
--- level, and a favorite applies its own volume, which the light is told as the command goes out.

require("lib.utils")

local Favorites = require("hatch.favorites")

--- The volume's facts: a dimmer with no color, whose changes run at once. A command reaches it through Hatch's
--- cloud, and the account tells its state again within 5 s.
--- @type LightDevice
local DEVICE = {
  dims = true,
  color = false,
  levelSteps = 100,
  fade = { kind = "own", own = { onMs = 0, offMs = 0, changeMs = 0 } },
  feedback = { shows = "target", waitMs = 5000, refresh = true },
}

--- What On plays: a favorite, a sound, or nothing chosen, which resumes the device's last sound.
--- @class HatchVolumeTarget
--- @field favoriteId string|integer|nil
--- @field favorite table|nil The favorite's record, for the volume it applies.
--- @field soundId string|integer|nil

--- The volume last sent, and the level of the command it was for.
--- @class HatchVolumeWire
--- @field pct integer
--- @field level number

--- @class HatchVolumeOptions
--- @field send fun(body: table) Sends an ENTITY_COMMAND body to the account.
--- @field refresh fun() Asks the account for the device's state.
--- @field target fun(): HatchVolumeTarget|nil What On plays now.

--- @class HatchVolume : LightAdapter
--- @field sendBody fun(body: table)
--- @field ask fun()
--- @field target fun(): HatchVolumeTarget|nil
--- @field wire HatchVolumeWire|nil
local Adapter = {}
Adapter.__index = Adapter
Adapter.DEVICE = DEVICE

--- @param opts HatchVolumeOptions
--- @return HatchVolume
function Adapter:new(opts)
  local instance = setmetatable({}, self)
  instance.sendBody = opts.send
  instance.ask = opts.refresh
  instance.target = opts.target
  instance.wire = nil
  return instance
end

--- Puts a command on the wire: a stop, a start of what On plays, or a volume.
--- @param cmd LightCommand
--- @return LightRest|nil rest The favorite's own volume, when one starts.
function Adapter:send(cmd)
  if not cmd.on then
    self.sendBody({ command = "off" })
    return nil
  end
  local pct = InRange(round(cmd.level * 100), 1, 100)
  if not cmd.fromOff then
    self.wire = { pct = pct, level = cmd.level }
    self.sendBody({ command = "setBrightness", brightness = pct })
    return nil
  end
  local target = self.target() or {}
  if target.favoriteId then
    self.sendBody({ command = "on", favoriteId = target.favoriteId })
    local favoritePct = Favorites.volumePct(target.favorite)
    if not favoritePct then
      self.wire = nil
      return nil
    end
    self.wire = { pct = favoritePct, level = favoritePct / 100 }
    return { level = favoritePct / 100 }
  end
  self.wire = { pct = pct, level = cmd.level }
  self.sendBody({ command = "on", soundId = target.soundId, brightness = pct })
  return nil
end

function Adapter:refresh()
  self.ask()
end

--- No device page.
function Adapter:show(_) end

--- The volume as the account told it. A volume the last command sent is that command's level.
--- @param state table { on, brightnessPct }
--- @return LightReport
function Adapter:report(state)
  local report = { kind = "push", on = state.on == true }
  local pct = tofinite(state.brightnessPct)
  if pct and pct > 0 then
    local wire = self.wire
    report.level = (wire and pct == wire.pct) and wire.level or InRange(pct, 0, 100) / 100
  end
  return report
end

return Adapter

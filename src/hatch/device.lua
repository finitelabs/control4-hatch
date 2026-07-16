-- Hatch device model: shadow <-> Control4 state.
--
-- Parses an AWS IoT device-shadow `reported` document into a flat state table,
-- and builds the `desired` patches published to control the device. Field names
-- and value encodings match the Hatch app / hatch_rest_api (RestIot family, used
-- by riot/riotPlus). Raw device values are 0..65535; percentages and 0..255
-- color channels are scaled to/from that range.

local Device = {}

local MAX_RAW = 65535
local NO_SOUND_ID = 19998
local NO_COLOR_ID = 9998
local CUSTOM_COLOR_ID = 9999
local CLOCK_ON_FLAG = 32768 -- 1 << 15

Device.NO_SOUND_ID = NO_SOUND_ID

local function clamp(n, lo, hi)
  if n < lo then
    return lo
  end
  if n > hi then
    return hi
  end
  return n
end

local function pctFromRaw(raw)
  return math.floor(clamp((tonumber(raw) or 0), 0, MAX_RAW) / MAX_RAW * 100 + 0.5)
end

local function rawFromPct(pct)
  return math.floor(clamp((tonumber(pct) or 0), 0, 100) / 100 * MAX_RAW + 0.5)
end

local function hexFromRaw(raw)
  return math.floor(clamp((tonumber(raw) or 0), 0, MAX_RAW) / MAX_RAW * 255 + 0.5)
end

local function rawFromHex(h)
  return math.floor(clamp((tonumber(h) or 0), 0, 255) / 255 * MAX_RAW + 0.5)
end
Device.pctFromRaw = pctFromRaw
Device.rawFromPct = rawFromPct

--- Parse a shadow `reported` document into a flat state table.
--- @param reported table|nil
--- @return table state
function Device.parseState(reported)
  reported = reported or {}
  local current = reported.current or {}
  local sound = current.sound or {}
  local color = current.color or {}
  local clock = reported.clock or {}

  local soundId = tonumber(sound.id)
  local colorId = tonumber(color.id)
  local flags = tonumber(clock.flags) or 0

  -- Prefer the authoritative `playing` field ("none"/"remote"/"routine"). The
  -- Restore keeps reporting its last soundId when idle, so deriving isPlaying
  -- from the soundId sentinel alone leaves it stuck "playing" its last routine.
  -- Fall back to the sentinel only when the device omits `playing`.
  local playing = current.playing
  local isPlaying
  if playing ~= nil then
    isPlaying = playing ~= "none"
  else
    isPlaying = soundId ~= nil and soundId ~= NO_SOUND_ID
  end

  return {
    online = reported.connected == true,
    playing = playing, -- "none" | "remote" | "routine"
    isPlaying = isPlaying,
    soundId = soundId,
    soundUrl = sound.url,
    volumePct = pctFromRaw(sound.v),
    srId = tonumber(current.srId),

    lightOn = colorId ~= nil and colorId ~= NO_COLOR_ID and colorId ~= 0,
    colorId = colorId,
    red = hexFromRaw(color.r),
    green = hexFromRaw(color.g),
    blue = hexFromRaw(color.b),
    brightnessPct = pctFromRaw(color.i),

    clockFlags = flags,
    clockOn = bit.band(flags, CLOCK_ON_FLAG) ~= 0,
    clockBrightnessPct = pctFromRaw(clock.i),

    batteryPct = tonumber((reported.deviceInfo or {}).b),
    firmware = (reported.deviceInfo or {}).f,
  }
end

-- ---- desired-state builders --------------------------------------------------
-- Each returns the `state.desired` table for Connection:updateShadow().

--- Play a sound. `sound` = { id, url }.
function Device.playSound(sound)
  return {
    current = {
      -- Clear any active routine. The device only re-triggers a routine when
      -- srId CHANGES; leaving a stale srId here means selecting that same
      -- favorite afterwards produces no shadow delta and silently does nothing.
      srId = 0,
      playing = "remote",
      step = 1,
      sound = {
        id = sound.id,
        url = sound.url,
        mute = false,
        ["until"] = "indefinite", -- `until` is a Lua keyword, so quote the key
      },
    },
  }
end

--- Stop all playback (sound and routine).
function Device.stop()
  return { current = { srId = 0, step = 0, playing = "none" } }
end

--- Play a favorite / routine by its numeric id.
function Device.playFavorite(favId)
  return { current = { srId = tonumber(favId) or 0, step = 1, playing = "routine" } }
end

--- Set sound volume (0..100).
function Device.setVolume(pct)
  return { current = { sound = { v = rawFromPct(pct) } } }
end

--- Set the RGB night light. `playing` is the device's current playing mode; when
--- nothing is playing the device requires playing="remote" to light up.
function Device.setColor(red, green, blue, brightnessPct, playing)
  local color = {
    id = CUSTOM_COLOR_ID,
    r = rawFromHex(red),
    g = rawFromHex(green),
    b = rawFromHex(blue),
    i = rawFromPct(brightnessPct),
    w = 0,
  }
  if playing == "none" or playing == nil then
    return { current = { srId = 0, step = 0, playing = "remote", color = color } }
  end
  return { current = { color = color } }
end

--- Turn the night light off. Mirrors hatch_rest_api: a remote-only light also
--- needs playing="none", while a routine light can go off on its own.
function Device.lightOff(playing)
  local off = { id = NO_COLOR_ID, r = 0, g = 0, b = 0, w = 0 }
  if playing == "remote" then
    return { current = { playing = "none", color = off } }
  end
  return { current = { color = off } }
end

--- Set clock (Time display) brightness (0..100); also turns the clock on.
function Device.setClock(brightnessPct, currentFlags)
  return {
    clock = {
      flags = bit.bor(tonumber(currentFlags) or 0, CLOCK_ON_FLAG),
      i = rawFromPct(brightnessPct),
    },
  }
end

--- Turn the clock display off.
function Device.clockOff(currentFlags)
  return {
    clock = {
      flags = bit.band(tonumber(currentFlags) or 0, bit.bnot(CLOCK_ON_FLAG)),
      i = 655,
    },
  }
end

return Device

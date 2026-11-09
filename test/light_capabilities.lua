-- A light_v2 driver.xml declares no capability without the proxy commands it brings.

local M = {}

--- What the proxy sends a light that declares each capability.
M.NEEDS = {
  on_off = { "ON", "OFF" },
  dimmer = { "SET_LEVEL" },
  set_level = { "SET_LEVEL" },
  supports_target = { "SET_BRIGHTNESS_TARGET" },
  ramp_level = { "RAMP_TO_LEVEL" },
  supports_default_on = { "SET_PRESET_LEVEL" },
  supports_brightness_stop = { "SET_BRIGHTNESS_STOP" },
  supports_color = { "SET_COLOR_TARGET" },
  supports_color_stop = { "SET_COLOR_STOP" },
  advanced_scene_support = { "PUSH_SCENE", "ACTIVATE_SCENE", "RAMP_SCENE_UP", "RAMP_SCENE_DOWN", "STOP_SCENE_RAMP" },
  reduced_als_support = { "RAMP_SCENE_UP", "RAMP_SCENE_DOWN", "STOP_SCENE_RAMP" },
  brightness_on_mode_preset = { "UPDATE_BRIGHTNESS_ON_MODE" },
  brightness_on_mode_previous = { "UPDATE_BRIGHTNESS_ON_MODE" },
  color_on_mode_fade = { "UPDATE_COLOR_ON_MODE" },
  color_on_mode_preset = { "UPDATE_COLOR_ON_MODE" },
  color_on_mode_previous = { "UPDATE_COLOR_ON_MODE" },
  click_rates = { "SET_CLICK_RATE_UP", "SET_CLICK_RATE_DOWN" },
  hold_rates = { "SET_HOLD_RATE_UP", "SET_HOLD_RATE_DOWN" },
}

--- Check that every capability `xmlPath` declares True has an RFP handler for each command it brings.
--- @param T table testlib
--- @param xmlPath string
function M.checkHandlers(T, xmlPath)
  local f = assert(io.open(xmlPath))
  local caps = f:read("*a"):match("<capabilities>(.-)</capabilities>")
  f:close()
  local names = {}
  for name in pairs(M.NEEDS) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    if caps:match("<" .. name .. ">(.-)</" .. name .. ">") == "True" then
      for _, command in ipairs(M.NEEDS[name]) do
        T.check(name .. " declared: RFP." .. command .. " handles it", type(RFP[command]) == "function")
      end
    end
  end
end

return M

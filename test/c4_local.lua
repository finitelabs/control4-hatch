--- What this driver's suites need that the template's c4_shim.lua does not model: a driver run as one build compiles
--- it. Requiring it installs ShimDofileBuild.

require("c4_shim")

local BUILDS = { drivercentral = { DRIVERCENTRAL = true }, oss = { OSS = true } }

--- Run the Lua file at `path` as `build` ("drivercentral" or "oss") compiles it: a line its directives leave out is
--- blanked, so line numbers stay the source's.
--- @param path string
--- @param build string
function ShimDofileBuild(path, build)
  local conditions = assert(BUILDS[build], build)
  local f = assert(io.open(path))
  local lines, stack, including = {}, {}, true
  for line in f:lines() do
    local ifdef, name = line:match("^%s*%-%-%s*#(ifn?def)%s+([%w_]+)%s*$")
    if ifdef then
      stack[#stack + 1] = including
      including = including and (conditions[name] == true) == (ifdef == "ifdef")
    elseif line:match("^%s*%-%-%s*#else%s*$") then
      including = stack[#stack] and not including
    elseif line:match("^%s*%-%-%s*#endif%s*$") then
      including = table.remove(stack)
    end
    lines[#lines + 1] = including and line or ""
  end
  f:close()
  return assert(load(table.concat(lines, "\n"), "@" .. path))()
end

-- Hatch cloud REST API client.
--
-- Runs the auth chain that ends in temporary AWS credentials for the IoT
-- MQTT-over-WebSocket connection:
--   1. POST public/v1/login                      -> member token
--   2. GET  service/app/iotDevice/v2/fetch        -> device list
--   3. GET  service/app/restPlus/token/v1/fetch   -> { region, endpoint, identityId, token }
--   4. POST cognito-identity GetCredentialsForIdentity (unsigned) -> temp AWS creds
--
-- All Hatch calls carry the member token in the X-HatchBaby-Auth header. The
-- Cognito call is a plain unsigned AWS JSON-1.1 POST. Everything is async via
-- Deferreds; `connect()` resolves with everything the connection layer needs.

local http = require("lib.http")
local deferred = require("deferred")
local JSON = require("JSON")
local log = require("lib.logging")

local API_BASE = "https://data.hatchbaby.com/"

-- The product families we ask the cloud to enumerate. Adding a new Hatch type
-- later is just a new entry here plus a device model in device.lua.
local IOT_PRODUCTS = { "restMini", "restPlus", "riot", "riotPlus", "restoreIot", "restoreV5" }

-- Restore (restoreV4/restoreV5) sound content is NOT served by the REST
-- content/fetchByProduct endpoint (it returns empty); it lives in Hatch's
-- Contentful CMS and is queried over GraphQL. The space + public delivery token
-- are Hatch's own (as used by the hatch_rest_api project); the member token is
-- passed through so Hatch's tier/entitlement layer applies.
local CONTENTFUL_URL = "https://graphql.contentful.com/content/v1/spaces/hlsdh3zwyrtx/environments/master"
local CONTENTFUL_TOKEN = "w81AL3BhokPlPGus5Pbs2UjK9hOEH-WYoJ4OOpOQpUI"
local RESTORE_SOUNDS_QUERY = [[
query GetSounds($product: String!) {
  soundCollection(
    limit: 1000
    where: {
      title_exists: true
      title_not_contains: "DVT: "
      wavFile_exists: true
      tier: "free"
      devices: { devCode_in: [$product] }
      hatchId_gt: 0
      hidden: false
    }
    order: [hatchId_ASC]
  ) {
    items {
      title
      id: hatchId
      wavFile {
        url
      }
      image {
        url
      }
    }
  }
}
]]

-- Cover art. Contentful is the only source carrying it and covers every device
-- family, including the riot catalog we otherwise fetch over REST, so artwork is
-- looked up by hatchId and merged onto whichever catalog was loaded.
local SOUND_ARTWORK_QUERY = [[
query GetSoundArtwork($product: String!) {
  soundCollection(
    limit: 1000
    where: {
      devices: { devCode_in: [$product] }
      hatchId_gt: 0
      image_exists: true
    }
    order: [hatchId_ASC]
  ) {
    items {
      id: hatchId
      image {
        url
      }
    }
  }
}
]]

--- @class HatchApi
local Api = {}
Api.__index = Api

--- @param opts table { email, password, userAgent? }
function Api:new(opts)
  local instance = setmetatable({}, self)
  instance.email = opts.email
  instance.password = opts.password
  instance.userAgent = opts.userAgent or "hatch_rest_api"
  instance.token = nil
  return instance
end

--- Headers for authenticated Hatch API calls.
function Api:authHeaders(extra)
  local headers = { ["User-Agent"] = self.userAgent, ["Content-Type"] = "application/json" }
  if self.token then
    headers["X-HatchBaby-Auth"] = self.token
  end
  for k, v in pairs(extra or {}) do
    headers[k] = v
  end
  return headers
end

-- C4's urlDo auto-decodes JSON bodies to tables; fall back to decoding a string.
local function bodyTable(response)
  if type(response.body) == "table" then
    return response.body
  end
  if type(response.body) == "string" and response.body ~= "" then
    local ok, decoded = pcall(function()
      return JSON:decode(response.body)
    end)
    if ok then
      return decoded
    end
  end
  return nil
end

--- POST public/v1/login -> member token (stored on self.token).
function Api:login()
  local url = API_BASE .. "public/v1/login"
  local body = JSON:encode({ email = self.email, password = self.password })
  return http:post(url, body, self:authHeaders()):next(function(response)
    local data = bodyTable(response)
    local token = data and (data.token or (data.payload and data.payload.token))
    if not token then
      return deferred.new():reject("login failed: no token in response")
    end
    self.token = token
    log:debug("Hatch login OK")
    return token
  end)
end

--- GET iotDevice/v2/fetch -> list of devices (product, name, thingName, macAddress).
function Api:fetchDevices()
  local query = {}
  for _, product in ipairs(IOT_PRODUCTS) do
    query[#query + 1] = "iotProducts=" .. product
  end
  local url = API_BASE .. "service/app/iotDevice/v2/fetch?" .. table.concat(query, "&")
  return http:get(url, self:authHeaders()):next(function(response)
    local data = bodyTable(response)
    return (data and data.payload) or {}
  end)
end

--- GET restPlus/token/v1/fetch -> { region, endpoint (host), identityId, token }.
function Api:fetchAwsToken()
  local url = API_BASE .. "service/app/restPlus/token/v1/fetch"
  return http:get(url, self:authHeaders()):next(function(response)
    local data = bodyTable(response)
    local payload = data and data.payload
    if not (payload and payload.token and payload.identityId and payload.region and payload.endpoint) then
      return deferred.new():reject("restPlus token fetch: incomplete payload")
    end
    return {
      region = payload.region,
      endpoint = (payload.endpoint:gsub("^https?://", "")),
      identityId = payload.identityId,
      token = payload.token,
    }
  end)
end

--- POST Cognito GetCredentialsForIdentity (unsigned) -> temporary AWS creds.
--- @param awsToken table result of fetchAwsToken()
function Api:fetchCognitoCreds(awsToken)
  local url = "https://cognito-identity." .. awsToken.region .. ".amazonaws.com"
  local body = JSON:encode({
    IdentityId = awsToken.identityId,
    Logins = { ["cognito-identity.amazonaws.com"] = awsToken.token },
  })
  local headers = {
    ["Content-Type"] = "application/x-amz-json-1.1",
    ["X-Amz-Target"] = "AWSCognitoIdentityService.GetCredentialsForIdentity",
    ["User-Agent"] = self.userAgent,
  }
  return http:post(url, body, headers):next(function(response)
    local data = bodyTable(response)
    local creds = data and data.Credentials
    if not (creds and creds.AccessKeyId and creds.SecretKey and creds.SessionToken) then
      return deferred.new():reject("cognito: no credentials in response")
    end
    return {
      accessKey = creds.AccessKeyId,
      secretKey = creds.SecretKey,
      sessionToken = creds.SessionToken,
      -- Cognito returns Expiration as a Unix timestamp (seconds).
      expiration = tonumber(creds.Expiration),
      region = awsToken.region,
      endpoint = awsToken.endpoint,
    }
  end)
end

-- Percent-encode a query value (the device mac contains ":").
local function urlEncode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- GET the sound catalog for a product family. riot/riotPlus use product "riot".
--- Resolves with a list of sound content items (id, title, and a url field).
function Api:fetchSounds(product)
  local url = API_BASE
    .. "service/app/content/v1/fetchByProduct?product="
    .. urlEncode(product)
    .. "&contentTypes=sound"
  return http:get(url, self:authHeaders()):next(function(response)
    local data = bodyTable(response)
    local payload = (data and data.payload) or {}
    -- payload.contentItems for v2 content; some responses return the list directly.
    return payload.contentItems or payload
  end)
end

--- POST the Contentful GraphQL sound catalog for Restore devices (restoreV4 /
--- restoreV5), which the REST fetchByProduct endpoint does not serve. Resolves
--- with a list of raw items ({ title, id, wavFile = { url } }) that loadCatalog
--- parses the same way as the REST catalog.
function Api:fetchRestoreSounds(product)
  local body = JSON:encode({
    query = RESTORE_SOUNDS_QUERY,
    variables = { product = product },
  })
  local headers = {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = self.userAgent,
    ["Authorization"] = "Bearer " .. CONTENTFUL_TOKEN,
  }
  if self.token then
    headers["X-HatchBaby-Auth"] = self.token
  end
  return http:post(CONTENTFUL_URL, body, headers):next(function(response)
    local data = bodyTable(response)
    local collection = data and data.data and data.data.soundCollection
    return (collection and collection.items) or {}
  end)
end

--- POST the Contentful GraphQL artwork lookup for a device family. Resolves with
--- a { [tostring(hatchId)] = imageUrl } map, which loadCatalog merges onto the
--- catalog regardless of whether it came from Contentful or REST. Resolves with
--- an empty map on failure: artwork is decoration, never a reason to fail a load.
--- @param product string Device family code, e.g. "riot" or "restoreV5".
function Api:fetchSoundArtwork(product)
  local body = JSON:encode({
    query = SOUND_ARTWORK_QUERY,
    variables = { product = product },
  })
  local headers = {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = self.userAgent,
    ["Authorization"] = "Bearer " .. CONTENTFUL_TOKEN,
  }
  if self.token then
    headers["X-HatchBaby-Auth"] = self.token
  end
  return http:post(CONTENTFUL_URL, body, headers):next(function(response)
    local data = bodyTable(response)
    local collection = data and data.data and data.data.soundCollection
    local byId = {}
    for _, item in ipairs((collection and collection.items) or {}) do
      local url = item.image and item.image.url
      if item.id and url then
        byId[tostring(item.id)] = url
      end
    end
    return byId
  end, function()
    return {}
  end)
end

--- GET routines/favorites for a device. `types` = "routine" for routines, nil
--- for favorites. Resolves with a list sorted by displayOrder.
function Api:fetchRoutines(mac, types)
  local url = API_BASE .. "service/app/routine/v2/fetch?macAddress=" .. urlEncode(mac)
  if types then
    url = url .. "&types=" .. urlEncode(types)
  end
  return http:get(url, self:authHeaders()):next(function(response)
    local data = bodyTable(response)
    return (data and data.payload) or {}
  end)
end

--- Full auth chain. Resolves with { token, devices, creds, region, endpoint }.
--- `creds` is ready to hand to SigV4.presignWssUrl().
---
--- Only the Cognito creds are short-lived (~1h) and need refreshing on each
--- reconnect; the member token from /login is good for ~24h. So we REUSE a
--- cached member token instead of logging in every reconnect -- Hatch rate-
--- limits /login aggressively (HTTP 429), and a full re-login per reconnect
--- turns a brief socket flap into a multi-minute outage. We re-login only when
--- a call is actually rejected for auth (401/403).
function Api:connect()
  local result = {}
  local function chain()
    return self
      :fetchDevices()
      :next(function(devices)
        result.devices = devices
        return self:fetchAwsToken()
      end)
      :next(function(awsToken)
        return self:fetchCognitoCreds(awsToken)
      end)
      :next(function(creds)
        result.token = self.token
        result.creds = creds
        result.region = creds.region
        result.endpoint = creds.endpoint
        return result
      end)
  end

  if self.token then
    return chain():next(nil, function(err)
      local code = type(err) == "table" and err.code
      if code == 401 or code == 403 then
        log:debug("Hatch: member token rejected (%s); re-logging in", tostring(code))
        self.token = nil
        return self:login():next(chain)
      end
      return deferred.new():reject(err)
    end)
  end
  return self:login():next(chain)
end

return Api

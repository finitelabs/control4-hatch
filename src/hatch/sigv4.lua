-- AWS Signature Version 4 presigning for AWS IoT MQTT-over-WebSocket.
--
-- Builds a presigned `wss://<endpoint>/mqtt` URL for the `iotdevicegateway`
-- service (GET, SignedHeaders=host, empty-payload hash). The Hatch cloud hands
-- us temporary AWS credentials via Cognito; this turns them into a URL the C4
-- WebSocket module can connect to directly.
--
-- C4 exposes no native HMAC, so HMAC-SHA256 is constructed from `C4:Hash`
-- ("SHA256"). The construction is verified against the standard
-- HMAC-SHA256("key", "The quick brown fox...") vector on a live controller.

local SigV4 = {}

-- SHA-256 of the empty string (canonical request's signed-payload hash).
local EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

local function sha256raw(data)
  return C4:Hash("SHA256", data, { return_encoding = "NONE" })
end

local function sha256hex(data)
  return C4:Hash("SHA256", data, { return_encoding = "HEX" })
end
SigV4.sha256hex = sha256hex

--- HMAC-SHA256 built on C4:Hash. `key` and `msg` are byte strings.
--- @param rawOut boolean when true returns 32 raw bytes, else lowercase hex.
local function hmac(key, msg, rawOut)
  local blockSize = 64
  if #key > blockSize then
    key = sha256raw(key)
  end
  key = key .. string.rep("\0", blockSize - #key)

  local oKeyPad, iKeyPad = {}, {}
  for n = 1, blockSize do
    local b = key:byte(n)
    oKeyPad[n] = string.char(bit.bxor(b, 0x5c))
    iKeyPad[n] = string.char(bit.bxor(b, 0x36))
  end

  local inner = sha256raw(table.concat(iKeyPad) .. msg)
  return C4:Hash("SHA256", table.concat(oKeyPad) .. inner, { return_encoding = rawOut and "NONE" or "HEX" })
end
SigV4.hmac = hmac

--- RFC 3986 percent-encoding, AWS style: unreserved set is A-Za-z0-9-_.~ and
--- everything else (including "/") is uppercase-hex escaped. Matches Python's
--- urllib.parse.quote(s, safe="").
local function urlEncode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end
SigV4.urlEncode = urlEncode

--- Build a presigned wss:// URL for AWS IoT MQTT.
--- @param creds table { region, endpoint (host, no scheme), accessKey, secretKey, sessionToken }
--- @param opts table|nil { now = unix time override, clientPath = "/mqtt" }
--- @return string presigned wss URL
function SigV4.presignWssUrl(creds, opts)
  opts = opts or {}
  local service = "iotdevicegateway"
  local host = creds.endpoint
  local uri = opts.clientPath or "/mqtt"

  local now = opts.now or os.time()
  local amzDate = os.date("!%Y%m%dT%H%M%SZ", now)
  local dateStamp = os.date("!%Y%m%d", now)
  local scope = dateStamp .. "/" .. creds.region .. "/" .. service .. "/aws4_request"

  -- Canonical query string: sorted, with the credential value url-encoded.
  local canonicalQuery = table.concat({
    "X-Amz-Algorithm=AWS4-HMAC-SHA256",
    "X-Amz-Credential=" .. urlEncode(creds.accessKey .. "/" .. scope),
    "X-Amz-Date=" .. amzDate,
    "X-Amz-SignedHeaders=host",
  }, "&")

  local canonicalRequest = table.concat({
    "GET",
    uri,
    canonicalQuery,
    "host:" .. host,
    "",
    "host",
    EMPTY_SHA256,
  }, "\n")

  local stringToSign = table.concat({
    "AWS4-HMAC-SHA256",
    amzDate,
    scope,
    sha256hex(canonicalRequest),
  }, "\n")

  local kDate = hmac("AWS4" .. creds.secretKey, dateStamp, true)
  local kRegion = hmac(kDate, creds.region, true)
  local kService = hmac(kRegion, service, true)
  local kSigning = hmac(kService, "aws4_request", true)
  local signature = hmac(kSigning, stringToSign, false)

  return "wss://"
    .. host
    .. uri
    .. "?"
    .. canonicalQuery
    .. "&X-Amz-Signature="
    .. signature
    .. "&X-Amz-Security-Token="
    .. urlEncode(creds.sessionToken)
end

return SigV4

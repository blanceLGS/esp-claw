-- Background TTS HTTP download (used by agent_then_tts stream path).
-- Writes response bytes to save_path as they arrive (save_direct).

local capability = require("capability")

local a = type(args) == "table" and args or {}

local url = a.url
local save_path = a.save_path
if type(url) ~= "string" or url == "" then
    error("url is required")
end
if type(save_path) ~= "string" or save_path == "" then
    error("save_path is required")
end

local headers = a.headers
if type(headers) ~= "table" then
    headers = {}
end

local timeout_ms = tonumber(a.timeout_ms) or 60000
local max_file_bytes = tonumber(a.max_file_bytes) or (1024 * 1024)

local ok, out, err = capability.call("http_request", {
    url = url,
    method = "POST",
    headers = headers,
    body = a.body,
    timeout_ms = timeout_ms,
    save_path = save_path,
    save_direct = true,
    max_file_bytes = max_file_bytes,
}, {
    source_cap = "agent_then_tts_http",
})

if not ok then
    error(string.format("tts download failed: %s", tostring(err or out)))
end
print(string.format("[tts_http_worker] %s", tostring(out)))

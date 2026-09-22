# Lua Crypto

Minimal helpers for iFlytek IAT auth and similar tasks.

## API

```lua
local crypto = require("crypto")
```

- `crypto.hmac_sha256(key, message)` → raw 32-byte HMAC-SHA256 string
- `crypto.base64_encode(data)` → base64 string
- `crypto.base64_decode(b64)` → raw string

## Example (IAT signature)

```lua
local origin = "host: iat.xf-yun.com\ndate: " .. date .. "\nGET /v1 HTTP/1.1"
local mac = crypto.hmac_sha256(api_secret, origin)
local signature = crypto.base64_encode(mac)
```

## Notes

- Backed by mbedTLS (`mbedtls_md` / `mbedtls_base64`).
- Inputs/outputs are Lua strings (binary-safe).

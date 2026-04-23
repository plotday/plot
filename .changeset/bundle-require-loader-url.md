---
"@plotday/twister": patch
---

Fixed: twist bundle banner now passes a literal `file:` URL to `createRequire` instead of `import.meta.url`. Cloudflare's Worker Loader leaves `import.meta.url` undefined, which caused every bundled twist/connector to throw `TypeError: path must be a file URL object...` at module-eval time and fail to deploy.

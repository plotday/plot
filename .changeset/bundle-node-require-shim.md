---
"@plotday/twister": patch
---

Fixed: `plot deploy` now bundles CJS dependencies that call `require("<node-builtin>")` (e.g. the asana SDK's `require("querystring")`). Previously the esbuild-generated `__require` stub would throw "Dynamic require of X is not supported" at runtime. The bundler now injects a module-level `require` built from `createRequire(import.meta.url)`, which Cloudflare Workers resolves via nodejs_compat.

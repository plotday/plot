---
"@plotday/twister": patch
---

Fixed: `plot build` (and therefore `plot deploy` / spec-driven twist generation) failed with "Could not resolve @plotday/twister" when run against the published package. The CLI bundler passes `conditions: ["@plotday/connector"]` to esbuild, and the package `exports` field points that condition at `./src/*.ts` — but the published tarball shipped only `dist/`, so every subpath import failed to resolve. Added `src` to the `files` field so the source files that the `@plotday/connector` condition references actually exist in the installed package.

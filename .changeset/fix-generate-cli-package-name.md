---
"@plotday/twister": patch
---

Fixed: `plot generate` was trying to install `@plotday/twist` (wrong package name) instead of `@plotday/twister`, causing post-generation dependency install to fail. Also updated `docs/CLI_REFERENCE.md` so the documented flags match the actual CLI (`--dir` / `--spec`, not `--input` / `--output`).

---
"@plotday/twister": patch
---

Fixed: `plot create` twist scaffold now emits the current Twist API (`activate()` plus `build(Plot, { thread: { access: ThreadAccess.Create } })`) instead of the removed `Activity`/`activity()` and the no-longer-exported `Priority` type, so a freshly scaffolded twist passes `plot lint`.

Fixed: `plot generate` now substitutes `{{packageManager}}` in the generated `AGENTS.md` (and uses the detected package manager for `README.md` instead of hardcoding `pnpm`), matching `plot create`.

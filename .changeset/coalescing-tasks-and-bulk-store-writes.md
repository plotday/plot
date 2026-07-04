---
"@plotday/twister": minor
---

Added: `scheduleTask` now accepts `coalesce: true`, which keeps an existing pending task under the same key instead of replacing it — the fire time is pulled earlier when the new `runAt` is sooner, but never pushed later. Use it for high-frequency triggers (e.g. scheduling a sync pass from a provider webhook) so a burst of N calls collapses into a single pending task instead of N queued executions. With `coalesce`, the passed callback may be discarded when an existing task is kept, so create a fresh callback per call and don't reuse its token.

Added: `Store.setMany(entries)` (also available as `this.setMany()` on Twist and Tool) writes many key/value pairs in one atomic round-trip. Prefer it over looping `set()` for batch writes — each `set()` is a network round-trip, so per-item loops dominate an execution's wall-clock time and request budget.

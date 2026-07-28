---
"@plotday/twister": minor
---

Added: `store.getMany()`, `store.listEntries()` and `store.clearMany()` — bulk read and delete counterparts to `setMany()`.

Each storage call a twist makes is a round-trip, and a worker execution has a fixed request budget shared by everything running in it. `setMany()` already covered batch writes, but the read and delete sides had no equivalent: draining buffered per-item state meant `list(prefix)` followed by a `get()` and a `clear()` per key, so a few hundred buffered items cost over a thousand serial round-trips — minutes of wall clock, and enough to exhaust the execution's request budget mid-pass.

- `listEntries(prefix)` returns matching keys **with** their values in one round-trip. The storage backend already reads the values during the prefix scan; `list()` simply discards them. Pair it with `clearMany()` and a drain costs two round-trips regardless of key count.
- `getMany(keys)` reads many known keys at once. Results are positionally aligned with the requested keys, with `null` for misses, so `keys[i]` ↔ `values[i]` is always safe to zip.
- `clearMany(keys)` deletes many keys atomically.

All three are available on `this.tools.store` and as protected helpers on `Tool` and `Twist` (`this.getMany()`, `this.listEntries()`, `this.clearMany()`).

Prefer `listEntries()` over `list()` whenever you intend to read the values anyway.

---
"@plotday/twister": patch
---

Fixed: `SerializableArray` (and thus `Serializable`) now accept `readonly` arrays, so fields declared with `readonly T[]` (e.g. `ReactionCapabilities.allowed`/`subset`) can be stored via `this.set()` / `Store.set()`.

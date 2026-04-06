---
"@plotday/twister": minor
---

Changed: `onNoteCreated` return type from `Promise<void>` to `Promise<string | void>` — returning a string sets the note's key for external system deduplication

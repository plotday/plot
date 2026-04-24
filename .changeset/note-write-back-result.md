---
"@plotday/twister": minor
---

Added: `NoteWriteBackResult` type and widened `onNoteCreated`/`onNoteUpdated` return types to accept it. Connectors performing two-way note sync can now return `{ key?, externalContent? }` so the runtime tracks a sync baseline of what the external system stored, preventing the next sync-in from clobbering Plot's (potentially richer-markdown) version with the round-tripped plain text. Back-compat preserved: `onNoteCreated` still accepts a plain string return.

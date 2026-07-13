---
"@plotday/twister": minor
---

Added: `Note.todayItem` — when a message is sent while a Today item is
pinned as context, the note carries `{ id }` pointing at that item. Twists
can read `note.todayItem` in a note handler to know which Today item a
message refers to. Read-only (not settable via `NewNote`).

---
"@plotday/twister": minor
---

Changed: `NewNote.unread` now controls read state on the `saveNotes` path. Omitting it leaves the thread's read state untouched, `true` marks the thread unread for everyone but the note's author, and `false` marks it read for the connection owner so a two-way read sync converges. Previously the field had no effect on notes saved through `saveNotes`.

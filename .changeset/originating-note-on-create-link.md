---
"@plotday/twister": minor
---

Added: `NewLinkWithNotes.originatingNote` ({ key, externalContent }) — `onCreateLink` can now bind the thread's opening note to the external message it created, so reactions and edits on the first message route back to the external system. Mirrors the `NoteWriteBackResult` a reply returns from `onNoteCreated`.

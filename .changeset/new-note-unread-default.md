---
"@plotday/twister": patch
---

Fixed: corrected the documented default for `NewNote.unread`.

Omitting the flag was described as "leave read state alone". It is not — attaching
a note marks its thread unread for every recipient except the note's author, and
there is no outcome that leaves read state untouched. A note that should not raise
unread must pass an explicit `false`.

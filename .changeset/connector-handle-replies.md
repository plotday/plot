---
"@plotday/twister": minor
---

Removed: `addContacts()` from Plot tool public API (contacts are created implicitly through thread/note creation)
Changed: `ContactAccess` enum now only has `Read` — `Write` removed from public API
Added: `handleReplies` static property on Connector class (replaces Plot tool options for defaultMention)

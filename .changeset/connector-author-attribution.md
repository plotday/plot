---
"@plotday/twister": minor
---

Changed: `NewLinkWithNotes.author` and `NewNote.author` now accept an explicit `null` to declare that an item is intentionally authorless (system-generated), alongside clearer JSDoc. Connectors should set `author` to the real external author on the link, its primary note, and every comment/message note; leaving it unset credits the item to the connector itself rather than a person. Passing `null` documents a deliberately authorless item and suppresses the development-time "missing author" warning.

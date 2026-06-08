---
"@plotday/twister": minor
---

Changed: `ComposeConfig.status` and `CreateLinkDraft.status` are now optional/nullable so status-less link types can still compose. Added: `NewLink.todo` / `NewLink.todoDate` to mark a thread as the connection owner's to-do atomically at create time.

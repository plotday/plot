---
"@plotday/twister": minor
---

Added: `Imap.watch()` / `Imap.unwatch()` — server-maintained IMAP IDLE push
watches. A connector can register a callback for a mailbox and the platform
holds the IDLE connection open, invoking the callback within seconds of new
mail or flag changes so incremental sync no longer waits for the next poll.
Includes the new `ImapWatchOptions` type.

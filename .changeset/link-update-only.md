---
"@plotday/twister": minor
---

Added: `NewLink.updateOnly` — save a link only as an update to a thread that already exists for its `source`/`sources`, never creating a new one. When no matching thread is found the link is skipped and `saveLink()` returns `null`. Use it for signals that only make sense as an update to an item the user already has (e.g. a calendar cancellation), so they never materialize a standalone thread for something that was never imported.

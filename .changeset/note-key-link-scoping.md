---
"@plotday/twister": patch
---

Changed: clarified that `Note.key` is scoped to a `(thread, link)` pair, not just a thread. Two links on the same thread can now each carry a note with the same key (e.g. `"description"`) without colliding. No API change — the runtime infers the link from the surrounding `saveLink` call.

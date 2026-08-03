---
"@plotday/twister": minor
---

Added: `isNoReplySender` to the signals entry point.

Identifies an address whose local part marks it as an automated or no-reply
sender. Connectors extracting mail signals can use it without depending on a
separate package.

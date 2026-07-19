---
"@plotday/twister": minor
---

Added: `NewContact.source.descriptor`, a display-only identifier connectors can supply alongside `source.accountId`. Use it for the most human-meaningful string a connection has for a person — a handle, phone number, or organisation — so Plot can show that instead of an opaque provider id. `accountId` remains the sole identity key and is unaffected.

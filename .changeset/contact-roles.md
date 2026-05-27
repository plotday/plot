---
"@plotday/twister": minor
---

Added: `LinkTypeConfig.contactRoles` and `supportsContactChanges` for per-connector contact role declarations (email To/CC/BCC, calendar Required/Optional, etc.). One role is marked `default`; roles marked `hidden` (BCC-style) are filtered server-side so they're only visible to the contact themselves and the user who added them. `NewContact` accepts an optional `role` that connectors set on inbound sync. New `Connector.onContactsChanged` callback fires when a user adds/removes contacts or changes a role on a thread.

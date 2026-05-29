---
"@plotday/twister": minor
---

Added: `ResolvedRecipient.role` so `onCreateLink` connectors can honor a contact's thread role (e.g. to/cc/bcc). The runtime resolves each recipient's role from the originating thread's `contact_meta`; connectors like Gmail use it to keep CC/BCC recipients out of the visible To header.

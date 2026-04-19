---
"@plotday/twister": minor
---

Added: `Connector.onCreateLink(draft)` hook and `CreateLinkDraft` type so connectors can create new items in external systems from Plot threads. A link type opts in by marking one of its statuses with `createDefault: true` on `LinkTypeConfig.statuses[]`; the status is also used as the default for newly created items. `CreateLinkDraft.contacts` carries the thread's contacts (excluding the creating user) so message/DM-style connectors can use them as recipients.

---
"@plotday/twister": minor
---

Fixed: a reply in a self-addressed thread (every participant is one of the sender's own linked addresses) resolved to no recipients and failed to send. `resolveOutboundReplyRecipients` now accepts an optional `headerFrom` input and, when the result would otherwise be empty only because every participant is self, addresses the reply back to the original sender so it stays deliverable.

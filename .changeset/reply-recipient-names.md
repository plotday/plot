---
"@plotday/twister": minor
---

Changed: resolveOutboundReplyRecipients now returns recipients as { address, name } objects instead of bare address strings, so email connectors can include display names in outbound To/Cc/Bcc headers.

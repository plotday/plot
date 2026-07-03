---
"@plotday/email-classifier": patch
---

Fixed: a directly-addressed reply is now classified as a message instead of a notification, even when the sending system stamps automated headers (support desks, ticketing systems). Previously short automated replies were swept into the muted FYI focus, burying real two-way conversations.

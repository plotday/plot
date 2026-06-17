---
"@plotday/twister": minor
---

Added: `DeliveryError` type plus `deliveryError` on `NoteWriteBackResult` and `NewLinkWithNotes.originatingNote`, so connectors can report an unrecoverable outbound send/write-back failure. The runtime records it on the note (the app shows a "Failed to send" affordance with Retry / Discard) and marks the thread unread. Connectors should return a `deliveryError` for expected, user-visible failures (rejected recipient, message too large) instead of throwing; throwing still surfaces a generic "Failed to send".

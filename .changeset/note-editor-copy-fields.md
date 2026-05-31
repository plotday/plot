---
"@plotday/twister": minor
---

Added: composePlaceholder, composeVerb, replyPlaceholder, replyVerb optional string fields on LinkTypeConfig. Connectors can now override the editor placeholder text and Send-button label per link type for both new-thread composition and in-thread replies. When unset, Plot derives values from existing label / noteLabel fields.

---
"@plotday/twister": minor
---

Changed: `Connector.onContactsChanged` role fields are now nullable (`role`/`from`/`to` may be `null`) so the callback can carry thread-level sharing changes for connectors without roles (e.g. group DMs), where only email connectors set To/Cc/Bcc roles. JSDoc clarified that the callback fires for `sharingModel: "thread"`/`"message"` membership changes, not channel-level sharing.

---
"@plotday/twister": minor
---

Added: `Integrations.getUserToken(channelId)` for retrieving provider-issued secondary user tokens (currently the Slack `authed_user.access_token`). Used by connectors that need user-scoped endpoints alongside bot-scoped sync.

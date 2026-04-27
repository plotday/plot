---
"@plotday/twister": minor
---

Added: `Integrations.markNeedsReauth(channelId)` for connectors to flag a channel's connection as needing re-authentication when an API call returns a permanent auth-style error (e.g. Slack `invalid_auth`, `token_revoked`). The runtime continues to flag reauth automatically on permanent token-refresh failures and on stored-token-missing reads; this method covers cases the runtime can't observe.

---
"@plotday/twister": minor
---

Added: `AuthProvider.LinkedIn` and a built-in `LinkedIn` tool that exposes a
provider-agnostic surface for the LinkedIn Voyager messaging API. The tool's
implementation lives in the API worker so request signing, header spoofing,
rate limiting, and cookie management stay out of open-source connector code.

Added: `LinkedIn.createConversation({ channelId, recipientUrns, text })` method
for starting a new 1:1 or group LinkedIn DM from Plot and sending the first
message atomically. Returns `{ conversationUrn, message }` so connectors can
store `conversationUrn` in `thread.meta` and reuse the existing
`onNoteCreated` reply path without extra wiring.

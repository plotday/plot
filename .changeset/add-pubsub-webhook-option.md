---
"@plotday/twister": minor
---

Added: `pubsub` option to `Network.createWebhook()` for creating Google Pub/Sub-backed webhooks. When `pubsub: true`, returns a Pub/Sub topic name instead of a webhook URL, enabling connectors to integrate with services that deliver events via Pub/Sub (e.g., Google Workspace Events API).

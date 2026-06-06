---
"@plotday/twister": minor
---

Changed: `Network.createWebhook` now selects a Google Pub/Sub push product via an explicit `pubsub: "gmail" | "workspace"` option (replacing the previous `pubsub: boolean`). Previously the Gmail Pub/Sub topic was chosen by auto-detecting Gmail scopes on stored Google auth tokens whenever no provider was passed, which misrouted a provider-less webhook for a sibling Google connector (Calendar, Drive) to a Gmail topic whenever the same user also had Gmail connected — `events.watch` / `files.watch` then rejected the non-HTTPS topic. Connectors now opt in explicitly: Gmail passes `pubsub: "gmail"`, Workspace Events (Chat) passes `pubsub: "workspace"`, and all other Google connectors receive a standard HTTPS webhook URL. Callers previously passing `pubsub: true` should pass `pubsub: "workspace"`.

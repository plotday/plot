---
"@plotday/twister": minor
---

Changed: replaced `LinkTypeConfig.targets` and the status-level `createDefault` flag with a single `LinkTypeConfig.compose` block that declares whether (and how) the link type is composable from Plot. Each `compose` carries `targets` (picker mode — `"channels"` / `"contacts"` / `"addresses"`), `status` (default status for created links — may be a symbolic id the connector resolves itself, e.g. Linear's per-team UUIDs), and optional `label` (picker copy override).

Connectors that need multiple compose modes for what users perceive as the same kind of thing (e.g. Slack channel post vs DM) should declare **separate linkTypes**, one per user-facing thread type. That keeps each linkType isomorphic to one filter chip.

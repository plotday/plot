---
"@plotday/twister": minor
---

Added: `SyncContext.observeOnly` — set when a channel is auto-observed because a user composed a Plot thread into it (rather than explicitly enabling it). Connectors should register webhooks/watches so inbound events sync back but skip historical backfill when this is true.

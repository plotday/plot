---
"@plotday/twister": minor
---

Added: `scheduleDrain(key, handler, options)` and `cancelDrain(key)` on Twist and Tool — the purpose-built primitive for webhook-driven sync and any high-frequency "something changed, process it soon" trigger. The platform records dirty item ids durably (one storage key per id, released only after the handler processes them — at-least-once and race-free under concurrent deliveries), collapses a burst of calls into a single pending pass per key, hands the handler at most `batchSize` ids per pass (scheduling continuations while a backlog remains), and drops ids that keep failing after `maxAttempts` so a poison item can't wedge the drain. Omit `ids` for signal-only drains where the handler derives its own work from a cursor or time window. The `__drain__:` storage-key namespace is reserved for this machinery.

---
"@plotday/twister": minor
---

Added: Tasks.scheduleRecurring(key, callback, { intervalMs, firstRunAt }) — a durable recurring task whose cadence is owned by the platform, so periodic chains (watch renewals, self-heal, polling) survive dropped runs, suspensions, and deploys instead of dying silently.

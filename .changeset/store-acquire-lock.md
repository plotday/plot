---
"@plotday/twister": minor
---

Added: `Store.acquireLock(key, ttlMs)` and `Store.releaseLock(key)` for TTL-aware locks. Replaces the boolean "in progress" flag pattern that connectors had to hand-roll, with self-expiring leases that survive crashed sync attempts. Lock keys live in a reserved namespace and never appear in `get` / `list` results.

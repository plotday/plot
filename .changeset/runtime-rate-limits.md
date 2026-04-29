---
"@plotday/twister": patch
---

Added: `RUNTIME.md` documents the per-twist-instance rate limits (200 invocations / 5 min burst, 500 / 24 h, cost limits) that the platform enforces, the auto-suspension behavior when they are exceeded, and the rule that suspensions are lifted automatically on the next deploy of the twist. Includes guidance on avoiding the most common cause of auto-suspension: unbounded `runTask` self-chains.

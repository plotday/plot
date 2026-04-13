---
"@plotday/twister": minor
---

Removed: `PickPriorityConfig` type and `pickPriority` field from `NewThread` and `NewLink`. Priority matching is now handled by user-defined priority rules on the server. Use `priority` for explicit placement or omit for automatic classification.

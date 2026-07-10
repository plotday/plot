---
"@plotday/twister": minor
---

Added: Goal entity types (`Goal`, `NewGoal`, `GoalUpdate`, `GoalStatus`, `GoalCadence` — importable from the package root or `@plotday/twister/goal`) and a Plot-tool goal surface: `Plot.Options.goals` with a `GoalAccess.Read`/`GoalAccess.Manage` permission level and `createGoal`/`getGoals`/`updateGoal`/`archiveGoal` methods, letting twists record and manage per-user goals.

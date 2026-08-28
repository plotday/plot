---
"@plotday/twister": major
---

Removed: the Today and goal surfaces from the Plot tool. The `TodayAccess` and `GoalAccess` permission enums are gone, along with the `today` and `goals` entries in `Plot.Options`, the `getTodayItems()`, `updateTodayItem()`, and `getTodayThreadId()` methods, the `createGoal()`, `getGoals()`, `updateGoal()`, and `archiveGoal()` methods, the `TodayItem`, `TodayItemSection`, and `TodayItemKind` types, the `Note.todayItem` field, and the `@plotday/twister/goal` entry point with its `Goal`, `NewGoal`, `GoalUpdate`, `GoalStatus`, and `GoalCadence` types. To upgrade, drop `today` and `goals` from your `build(Plot, { ... })` options and remove any calls to those methods; a twist that stored per-user intentions through goals can keep them in its own state with `this.set` / `this.get`. Note that the thread `type` value `"goal"` is unaffected — it is a display sub-type and remains available.

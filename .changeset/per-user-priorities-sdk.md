---
"@plotday/twister": minor
---

Changed: Twists are now workspace-level (installed by a user, not by a priority). `Twist.activate()` no longer receives a `priority` argument, `Tool.preActivate`/`postActivate` drop their `priority` argument, and `Channel.priorityId` is gone — priority routing happens automatically server-side via `match_priority_for_user` when a twist creates threads or links without an explicit target. Added: `this.userId` on `Twist` (the installing user's ID) and new `Plot.getUserId()` / `Plot.getDefaultPriorityId()` helpers for twists that need to resolve the owner or their root priority explicitly.

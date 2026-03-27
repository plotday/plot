---
"@plotday/twister": minor
---

Added: `ThreadAccess.Full` permission level for listing, updating, and moving any thread in the twist's priority scope, and creating notes on any thread.
Added: `LinkAccess` enum (`Read`, `Full`) for reading and updating links, including moving links between threads.
Added: `PlanOperation` type and `ActionType.plan` for submitting structured operation plans that require user approval.
Added: `getThreads()` method to list threads across a priority and its descendants.
Added: `getPriorities()` method to list priorities within the twist's scope.
Added: `updateLink()` method to update links (including moving between threads).
Added: `createPlan()` method to build approval-gated operation plans.
Added: `priority` field on `ThreadUpdate` to move threads between priorities.
Added: `parent` field on `PriorityUpdate` to move priorities under a new parent.
Added: `LinkUpdate` type for link updates.
Added: `requireApproval` option on `Plot.Options` to gate admin writes behind user approval.

---
"@plotday/twister": minor
---

Added: `createFocus` plan operation, `approved`/`results` fields on plan actions, and `PlanOperationResult` — plan operations are now executed server-side when the user approves, and the plan callback receives `(action, approved)` with per-operation results on the action.

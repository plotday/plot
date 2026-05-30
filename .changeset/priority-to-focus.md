---
"@plotday/twister": minor
---

Changed: renamed the Priority concept to Focus across the SDK public surface. `Priority`/`NewPriority`/`PriorityUpdate` are now `Focus`/`NewFocus`/`FocusUpdate`; `PriorityAccess` is now `FocusAccess`; the `Plot` tool methods `createPriority`/`getPriority`/`updatePriority`/`getPriorities` are now `createFocus`/`getFocus`/`updateFocus`/`getFocuses`; `Thread.priority` is now `Thread.focus`; search/list `priorityId` options are now `focusId`; and the `PlanOperation` priority shapes are now focus shapes (`updateFocus`, `focusId`, `focusTitle`). Focuses are flat — `parent` (nesting) has been removed from `NewFocus`/`FocusUpdate` and the list options no longer take `parentId`/`includeDescendants`. Added `Focus.icon`.

---
"@plotday/twister": minor
---

Changed: NewScheduleOccurrence.archived renamed to cancelled. Per-instance cancellations now have an explicit semantic distinct from archiving an override row. Connectors should emit `cancelled: true` for skipped occurrences; the runtime translates these into additions on the parent schedule's `recurrenceExdates`.

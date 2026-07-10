---
id: store-lifecycle
category: state
difficulty: medium
assertions:
  - match: 'this\.set\b|store\.set\b|setMany'
    why: the count must be persisted, not kept in memory
  - match: 'this\.get\b|store\.get\b'
    why: the count must be read back across executions (generic call forms like this.get<number>(...) count)
  - match: 'scheduleRecurring|scheduleTask|runTask'
    why: the weekly report must be scheduled
allowDeps: []
---
# Weekly report counter

Every Monday morning, create a thread titled "Weekly report #<n>" where n
starts at 1 and increases by one each week. The note should say how many
weekly reports have been posted so far. The counter must survive restarts —
if the twist is restarted mid-week, numbering must not reset.

---
id: thread-actions
category: actions
difficulty: medium
assertions:
  - match: 'ActionType\.callback|type:\s*["'']callback["'']'
    why: buttons must be callback actions
  - match: 'scheduleRecurring|scheduleTask|runTask'
    why: the standup thread must be scheduled each weekday
allowDeps: []
---
# Daily standup check-in

Every weekday morning, create a thread titled "Standup <date>" containing a
note that asks "How's it going?" with two buttons: "On track" and
"Blocked". When I press one, add a note to the thread recording my choice
(for example "Marked: Blocked").

---
"@plotday/twister": minor
---

Removed: 10 toggle-tag entries (`Tag.Pinned`, `Tag.Urgent`, `Tag.Goal`, `Tag.Decision`, `Tag.Waiting`, `Tag.Blocked`, `Tag.Warning`, `Tag.Question`, `Tag.Star`, `Tag.Idea`) and the `tag?: Tag` field on `LinkTypeConfig.statuses[]`. The status-tag propagation mechanism is retired — connectors signal completion via the `done: true` boolean and messaging-active state via `active: true`, which is what was driving behaviour anyway. Reactions on threads/notes flow exclusively through the open Unicode emoji `Reaction` type.

Changed: `Tag.Twist` moves from `109` (toggle range) to `12` (compute range). It's still the system marker for "a twist is processing this note"; the runtime keeps writing/clearing it, and twists may still toggle it via `note.twistTags`. Code referencing `Tag.Twist` recompiles transparently against the new id.

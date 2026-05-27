---
"@plotday/twister": minor
---

Removed: count-tag entries (`Tag.Yes` through `Tag.Dismayed`, IDs 1000–1027) from the `Tag` enum. The full Unicode emoji `Reaction` type (added in the previous changeset) replaces them; connectors that previously wrote `note.tags[Tag.Yes]` now write `note.reactions['👍']`. Compute (Todo, Done) and toggle tags (Pinned, Urgent, …, Idea) are unchanged.

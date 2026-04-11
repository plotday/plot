---
"@plotday/twister": minor
---

Added: `todo` boolean on `LinkTypeConfig.statuses[]` so connectors can indicate which status represents the active/to-do state (e.g. Gmail's "starred", Linear's "To Do"). When a user adds a thread to Plot's agenda, done-status links flip to this status so the link widget and thread tags reflect the active state.

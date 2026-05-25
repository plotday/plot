---
"@plotday/twister": minor
---

Added: `active`, `task`, and `toRead` flags on `LinkTypeConfig.statuses[]` so connectors can declare per-status intent for the unified Plot feed. `active` lands threads in Doing (use for messaging flags like Gmail star / Slack later), `task` lands them on the task list (use for tracker assignments like Linear / Todoist), `toRead` lands them on the reading list. The existing `todo` flag is deprecated and treated as `task: true` for backward compatibility.

---
"@plotday/twister": minor
---

Removed: `Plot.getDefaultPriorityId()`. Connectors and twists no longer have access to a fallback "root" priority. All thread routing happens server-side via classification (which is team-aware as of this release). Twists that need an explicit priority should pull it from their @-mention context (e.g. `note.thread.priority.id`).

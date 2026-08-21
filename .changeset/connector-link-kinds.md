---
"@plotday/twister": minor
---

Added: `kind` to `LinkTypeConfig` so connectors can declare what each link type is: `calendar`, `task`, `team-task`, or `message`. Plot uses this to group connectors and to decide which channels of a connection a workspace can enable, so a composite connector's calendar and mail channels can be treated differently. The field is optional and defaults to `team-task`; declare it on every link type you publish.

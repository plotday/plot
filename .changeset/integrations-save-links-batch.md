---
"@plotday/twister": minor
---

Added: `Integrations.saveLinks(links)` batch API. Connectors that sync many items per page should prefer this over looping `saveLink` — each call crosses the runtime boundary and counts against the per-execution request budget.

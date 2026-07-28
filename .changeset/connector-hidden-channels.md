---
"@plotday/twister": minor
---

Added: `Connector.hiddenChannels` — declare that a connector's channels are internal detail rather than a user choice. Channels are still reported and mirrored so links keep their channel attribution, but no channel picker is shown and enable/disable is not offered. Use it for connectors whose sync scope is decided by rules rather than channel selection.

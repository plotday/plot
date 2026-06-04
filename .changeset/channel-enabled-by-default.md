---
"@plotday/twister": minor
---

Added: `enabledByDefault?: boolean` (tri-state) on the `Channel` type returned by `getChannels()`. Lets a connector influence which channels are pre-selected when a connection is first added: `true` pre-selects, `false` excludes a low-value/irrelevant channel or a too-broad container (e.g. a holiday or someone-else's shared calendar, a GitHub org that cascades to every repo, a Teams team container), and `undefined` leaves the choice to the client (which enables the channel unless its title looks low-value). The setup UI now defaults to enabling all top-level channels and filtering out the low-value ones, rather than picking a single "primary."

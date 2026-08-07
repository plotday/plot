---
"@plotday/twister": minor
---

Added: `LinkSignals.taxonomy` — namespaced structured-container keys
(`"<connector>:<kind>:<id>"`, e.g. `"linear:project:<uuid>"`) a connector
emits for the project, repository, board or folder an item lives in. The
platform matches these exactly against priority bindings to route items to
the user's priorities without a model call. Use immutable ids, never display
names; omit the field when the source has no structured container.

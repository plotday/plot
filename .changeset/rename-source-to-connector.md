---
"@plotday/twister": minor
---

Changed: BREAKING: Renamed Source to Connector across the SDK. The `Source` class is now `Connector`, the `./source` export is now `./connector`, and all `@plotday/source-*` packages are now `@plotday/connector-*`. A deprecated `Source` alias is re-exported for backward compatibility.

---
"@plotday/twister": minor
---

Changed: Replaced the OAuth-only `ScopeConfig.description` with a connector-level `Connector.access` — plain-language bullets describing what access connecting a service grants, shown on every connect screen regardless of auth mechanism. `ScopeConfig.description` is removed; declare `Connector.access` on the connector instead.

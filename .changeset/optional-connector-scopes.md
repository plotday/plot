---
"@plotday/twister": minor
---

Added: `ScopeConfig` for a connector's `scopes` — declare `required` scopes, an optional `description` (friendly permission bullets shown at connect time), and `optional` scope groups the user can toggle. Auth now succeeds even when optional scopes are declined; connectors detect the result via the granted `token.scopes`.

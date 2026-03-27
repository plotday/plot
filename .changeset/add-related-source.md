---
"@plotday/twister": minor
---

Added: `relatedSource` field on `Link` type for cross-connector thread bundling. Links whose `source` matches another link's `relatedSource` automatically share the same thread, regardless of creation order.

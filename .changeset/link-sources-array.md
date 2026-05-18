---
"@plotday/twister": minor
---

Added: `NewLink.sources: string[]` for cross-connector thread bundling via canonical aliases. Two links whose `sources` arrays overlap share a thread. `NewLink.source` (single string) and `NewLink.relatedSource` are deprecated — the runtime normalizes legacy values into `sources` on save, so existing connectors keep working unchanged.

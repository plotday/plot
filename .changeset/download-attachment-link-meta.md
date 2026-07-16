---
"@plotday/twister": minor
---

Added: `Connector.downloadAttachment` now receives an optional second parameter, `linkMeta` — the `meta` of the link owning the fileRef's note (the same connector-authored metadata surfaced as `thread.meta` in write-back callbacks). Connectors whose fileRef values don't encode everything needed to fetch the bytes (e.g. chat connectors whose provider requires the chat id as well as the message id) can read it from `linkMeta` instead of re-deriving it. Existing connectors that only use `ref` are unaffected.

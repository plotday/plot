---
"@plotday/twister": minor
---

Changed: `NewContact.source` no longer includes `provider` — the runtime stamps it from the dispatching twist instance. Connectors should drop `source.provider` and pass just `source: { accountId }`.
Added: `LinkTypeConfig.targets` accepts `"addresses"` for link types whose recipients can be any addressable identifier (e.g. an email) rather than a contact pre-registered through the connection. Used by Gmail.

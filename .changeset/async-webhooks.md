---
"@plotday/twister": minor
---

Changed: `network.createWebhook()` now runs callbacks asynchronously by
default. Incoming requests are enqueued and acknowledged with `200`
immediately; a background queue consumer dispatches each callback with
bounded concurrency, so bursts of webhook traffic (e.g. a CRM bulk import)
no longer exhaust database connections or cause sender-side retry storms.

The new `async?: boolean` option defaults to `true`. Callbacks that must
return a response the sender reads — Microsoft Graph validation echoes,
handlers that surface HTTP status codes, or any interactive webhook — must
opt out with `{ async: false }`.

Async delivery is at-least-once: callbacks must be idempotent. When
`async: false`, returning a `string` from the callback produces a
`text/plain` response body (required for Microsoft Graph subscription
validation); any other value is serialized as JSON, and `undefined`
yields `200 OK`.

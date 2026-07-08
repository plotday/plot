---
id: external-dep
category: deps
difficulty: medium
assertions:
  - match: 'zod|valibot|ajv'
    why: must use a schema-validation library
  - match: 'createWebhook'
    why: must expose a webhook endpoint
allowDeps:
  - zod
---
# Home automation events

My home automation system can POST JSON to a URL. Give me an endpoint for
it. Each payload should look like {"device": string, "event": string,
"at": ISO-8601 timestamp}. Validate incoming payloads strictly with a
schema-validation library (zod is fine) — create a thread titled
"<device>: <event>" only for valid payloads, and silently ignore anything
malformed.

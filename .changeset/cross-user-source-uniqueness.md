---
"@plotday/twister": patch
---

Changed: `source` is now cross-user-scoped — two instances of the same connector emitting the same `source` converge on a single shared thread across users. Documented the requirement that `source` must be globally unique for the logical external item, and called out connectors whose external ids are workspace/tenant-scoped (attio, posthog, outlook-calendar, fellow) and need qualifiers.

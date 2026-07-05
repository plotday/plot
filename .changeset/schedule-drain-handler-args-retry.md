---
"@plotday/twister": minor
---

Added: `scheduleDrain` now supports `handlerArgs` (extra serializable arguments appended after the ids slice when the handler is invoked — for per-scope drains such as a per-channel key whose handler needs the channel id) and a partial-failure contract: the handler may return `{ retry: ids }` to keep just the failed ids pending with bumped attempt counters while releasing the rest of the slice.

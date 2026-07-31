---
"@plotday/twister": minor
---

Added: `TextDef.required` on the `Options` tool. When set, the Flutter connect/edit form blocks submission while the field is empty (secure fields were already implicitly required). Text fields with no sensible default — like a workspace subdomain — can now opt in to this instead of silently accepting a blank value that only fails once the connector tries to use it.

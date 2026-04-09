---
"@plotday/twister": minor
---

Changed: Thread and Note visibility model — replaced `private` boolean with `access` enum ('public'|'members'|'restricted') and `accessContacts` array on Thread, and replaced `private` boolean with `accessContacts` array on Note. Removed `mentions` from Thread type. Note `mentions` now contains only twist/connector IDs for dispatch routing.

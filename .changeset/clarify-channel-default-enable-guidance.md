---
"@plotday/twister": patch
---

Changed: clarified the `Channel.enabledByDefault` doc comment to recommend an explicit "is this the user's own resource" signal over an ACL/permission-tier check when deciding which channels to sync by default — a high permission tier can be granted on a resource the user doesn't own (e.g. broad internal sharing defaults), so it doesn't reliably mean "mine".

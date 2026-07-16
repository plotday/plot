---
"@plotday/twister": minor
---

Changed: `markdownToPlainText` now renders labeled links as `label (url)` instead of collapsing them to the label alone, so the destination URL survives when a note is written back to a plain-text target (chat messages, comments, cells). Links whose label is empty or identical to the URL still collapse to the bare URL.

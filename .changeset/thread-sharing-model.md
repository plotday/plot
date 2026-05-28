---
"@plotday/twister": minor
---

Added: `sharingModel` field on `LinkTypeConfig` to declare per-link-type sharing scope (`"thread"`, `"channel"`, or `"message"`). Defaults to `"thread"` when omitted. Connectors use `"channel"` for membership-based containers (Slack channels, Linear projects) and `"message"` for per-recipient threads (email).

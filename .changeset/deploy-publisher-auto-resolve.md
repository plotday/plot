---
"@plotday/twister": patch
---

Fixed: `plot deploy` now reads `publisher` and `publisherUrl` from package.json to auto-resolve the publisher for non-personal deployments, and fails with exit code 1 in non-interactive environments instead of silently succeeding.

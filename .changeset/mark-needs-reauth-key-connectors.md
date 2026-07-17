---
"@plotday/twister": patch
---

Changed: `integrations.markNeedsReauth` now also works for key-based (API-key) connectors — calling it flags the connection so the app prompts the user to re-enter their key. Previously it was documented as a no-op for key-based connectors.

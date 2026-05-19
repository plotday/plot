---
"@plotday/twister": minor
---

Added: `AuthProvider.LinkedIn` and a built-in `LinkedIn` tool that exposes a
provider-agnostic surface for the LinkedIn Voyager messaging API. The tool's
implementation lives in the API worker so request signing, header spoofing,
rate limiting, and cookie management stay out of open-source connector code.

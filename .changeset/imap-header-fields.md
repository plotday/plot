---
"@plotday/twister": minor
---

Added: `ImapMessage` now carries `listId`, `listUnsubscribe`, `precedence`, `autoSubmitted`, `returnPath`, `importance`, `xPriority`, and `authenticationResults` (the raw values of any headers a connector's IMAP fetch picked up), so an IMAP-based mail connector can build classifier signals the same way the Gmail and Outlook connectors already do.

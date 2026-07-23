---
"@plotday/twister": minor
---

Added: `ImapMailboxStatus.highestModSeq` — surfaces a mailbox's CONDSTORE (RFC 7162) `HIGHESTMODSEQ` high-water mark when the IMAP server advertises it. Connectors can persist this value as a since-last-poll cursor and skip re-scanning a mailbox whose mod-sequence hasn't advanced, instead of refetching a recent-message window every poll. The field is absent when the server or mailbox does not support mod-sequences.

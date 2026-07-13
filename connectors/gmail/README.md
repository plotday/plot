# Gmail Connector for Plot

> **Library note:** This package is consumed by [`@plotday/connector-google`](../google), the deployed "Gmail & Calendar" connection — it is not deployed as a standalone connector. See `../AGENTS.md` for details.

Sync Gmail into Plot. Each Gmail thread becomes a Plot thread; each message becomes a note.

## What it does

- Syncs mail via Gmail push notifications (Cloud Pub/Sub), with historyId-based incremental sync
- Marking a thread read/unread or To Do in Plot writes back to Gmail (labels)
- Replies and new mail composed in Plot send via the Gmail API
- HTML message bodies are passed through for server-side markdown conversion

## License

MIT © Plot Technologies Inc.

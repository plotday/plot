---
"@plotday/twister": minor
---

Added: `ActionType.fileRef` and `Connector.downloadAttachment` for source-hosted attachments, plus the `Files` tool with `read(fileId)` for outbound R2 reads. Connectors emit `fileRef` actions during inbound sync and serve their bytes on demand via `downloadAttachment`. Outbound continues to use `ActionType.file` backed by Plot's R2 storage.

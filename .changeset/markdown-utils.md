---
"@plotday/twister": minor
---

Added: `@plotday/twister/utils/markdown` with `markdownToPlainText(markdown)` for connectors that write back to external systems storing content verbatim as plain text (Google Drive comments, Todoist comments, Airtable cells, Attio notes). Renumbers lists, keeps bullet markers and paragraph breaks, strips emphasis/code syntax, and renders mentions as `@Name`. Pure in-process function — no RPC cost on `onNoteCreated` / `onNoteUpdated`.

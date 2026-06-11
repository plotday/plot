# Google Drive Connector for Plot

Sync Google Drive document comments into Plot.

## What it does

- Lists your Drive folders (My Drive, shared drives, and "Shared with me") as channels
- Syncs files in enabled folders (Docs, Sheets, Slides, Forms, and other documents) as Plot threads
- Syncs comments and replies as notes; comments with assignees are tagged as to-dos
- Replying in Plot posts the comment or reply back to Drive, and edits sync both ways
- Real-time updates via Drive change notifications, renewed automatically

File content is not synced — only file metadata, comments, and replies.

## OAuth scopes

- `drive` — read files and comments, write comments
- Google Contacts scopes — add names to the people on comments

## License

MIT © Plot Technologies Inc.

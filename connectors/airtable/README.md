# Airtable Connector for Plot

Sync Airtable task lists into Plot and collaborate on them with two-way comment sync.

## What it does

- Auto-detects task-like tables across your enabled bases (collaborator + due-date + status fields)
- Syncs records assigned to you as Plot threads with status and due date
- Two-way comment sync: comments on Airtable records appear as notes; notes you write in Plot post back as comments
- Marking a task done in Plot flips the status field / checkbox in Airtable

## OAuth scopes

- `user.email:read` — identify the connected user
- `schema.bases:read` — list bases, tables, and field definitions for auto-detection
- `data.records:read` / `data.records:write` — read and update records
- `data.recordComments:read` / `data.recordComments:write` — two-way comment sync
- `webhook:manage` — receive real-time updates

## License

MIT

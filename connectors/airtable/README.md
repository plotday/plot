# Airtable Connector for Plot

Sync Airtable task lists into Plot.

## What it does

- Auto-detects task-like tables across your enabled bases (collaborator + due-date + status fields)
- Syncs records assigned to you as Plot threads with status and due date
- Marking a task done in Plot flips the status field / checkbox in Airtable

Comments are not synced. Airtable's standard webhooks don't notify on comment changes (that's an Enterprise-only Change Events feature), so a reliable two-way comment flow isn't possible on standard plans.

## OAuth scopes

- `user.email:read` — identify the connected user
- `schema.bases:read` — list bases, tables, and field definitions for auto-detection
- `data.records:read` / `data.records:write` — read and update records
- `webhook:manage` — receive real-time updates

## License

MIT

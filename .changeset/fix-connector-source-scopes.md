---
"@plotday/twister": patch
---

Fixed: qualify `source` strings in workspace/tenant/mailbox-scoped connectors so they stay globally unique under cross-user thread dedup. attio now uses `attio:<workspaceId>:<type>:<recordId>`; posthog uses `posthog:<projectId>:person:<distinctId>`; outlook-calendar uses `outlook-calendar:<calendarId>:<eventId>`; fellow uses `fellow:<subdomain>:note:<id>`. google-calendar now uses the event's `iCalUID` (shared across attendees' copies) in place of the per-calendar event id, so the same meeting converges into one thread across users.

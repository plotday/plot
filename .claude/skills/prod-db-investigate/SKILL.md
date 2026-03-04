---
name: prod-db-investigate
description: Investigate the production database with readonly access. Use when the user asks to look at production data, debug production issues, or investigate the prod DB.
---

# Production Database Investigation

You have readonly access to the production database via the `prod-db` MCP server.

## Prerequisites

Before running any queries, ensure the connection is working:

1. **Cloud SQL Proxy must be running** on port 5433:
   ```bash
   pnpm --filter @plotday/db prod-db-connect
   ```
   Verify: `nc -z localhost 5433 && echo "OK"`

2. **1Password CLI must be authenticated**:
   ```bash
   op whoami
   ```
   If not authenticated: `eval $(op signin)`

3. **The `prod-db` MCP server must be connected.** If it failed to start (because the proxy wasn't running when Claude Code launched), you need to restart Claude Code after starting the proxy. Alternatively, use `psql` directly:
   ```bash
   PGPASSWORD=$(op read --account plotco.1password.com "op://Production/Database/readonly/password") psql -h 127.0.0.1 -p 5433 -U readonly -d plot
   ```

## Schema Reference

Before querying, **read the local schema files in `libs/db/schema/`** to identify correct table/view names and columns. Production may differ slightly, but the local schema is the best reference.

Key conventions:
- **Table names are singular** (e.g. `activity`, `note`, `priority`, `thread` — not `activities`, `threads`)
- **`public` schema**: Core tables (activity, note, priority, tag, etc.)
- **`"user"` schema**: Views used for user sync in the Flutter app (must be quoted as `"user"` in SQL)
- Schema files are organized in subdirectories: `50-tables/`, `60-functions/`, `70-views/`, `90-user-schema/`, `95-triggers/`, etc.

## Using the MCP Server

Use `mcp__prod-db__*` tools for structured access:
- `mcp__prod-db__execute_sql` - Run SELECT queries
- `mcp__prod-db__list_tables` - Browse table schemas
- `mcp__prod-db__list_indexes` - Check indexes
- `mcp__prod-db__get_query_plan` - Analyze query plans
- `mcp__prod-db__list_table_stats` - Table statistics

## Rules

- **READONLY**: Only run SELECT queries. Never INSERT, UPDATE, DELETE, DROP, ALTER, or TRUNCATE.
- **No PII in output**: Redact or summarize personal data (emails, names) — show counts and patterns, not raw PII.
- **Limit result sets**: Always use LIMIT (default 100) to avoid pulling large datasets.
- **No schema changes**: This user cannot modify the schema, but don't even attempt it.
- **Performance**: Avoid full table scans on large tables. Check the query plan first if unsure.

## Connection Details

- Host: 127.0.0.1
- Port: 5433
- User: readonly
- Database: plot
- Password: `op://Production/Database/readonly/password` (fetched via 1Password CLI)

## Fallback: Direct psql

If the MCP server isn't available, use psql via Bash:
```bash
PGPASSWORD=$(op read --account plotco.1password.com "op://Production/Database/readonly/password") psql -h 127.0.0.1 -p 5433 -U readonly -d plot -c "SELECT ..."
```

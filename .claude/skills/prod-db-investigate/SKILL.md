---
name: prod-db-investigate
description: Investigate the production database with readonly access. Use when the user asks to look at production data, debug production issues, or investigate the prod DB.
---

# Production Database Investigation

You have readonly access to the production database via `psql` over a Cloud SQL Proxy.

## Running Queries

Use this command template via Bash:

```bash
PGPASSWORD=$PROD_DB_PASSWORD psql -h 127.0.0.1 -p 5433 -U readonly -d plot -c "SELECT ..."
```

For multi-line queries, use a heredoc:

```bash
PGPASSWORD=$PROD_DB_PASSWORD psql -h 127.0.0.1 -p 5433 -U readonly -d plot <<'SQL'
SELECT ...
FROM ...
WHERE ...
LIMIT 100;
SQL
```

## Auto-Start Proxy

Before your first query each session, ensure the Cloud SQL Proxy is running:

```bash
nc -z 127.0.0.1 5433 2>/dev/null || pnpm prod-db-connect
```

If the proxy isn't running, start it and wait briefly for it to be ready:

```bash
pnpm prod-db-connect && sleep 2
```

Each `psql` invocation is a fresh connection, so if the proxy bounces between queries, the next query will just work once it's back up.

## Schema Reference

Before querying, **read the local schema files in `libs/db/schema/`** to identify correct table/view names and columns. Production may differ slightly, but the local schema is the best reference.

Key conventions:
- **Table names are singular** (e.g. `activity`, `note`, `priority`, `thread` — not `activities`, `threads`)
- **`public` schema**: Core tables (activity, note, priority, tag, etc.)
- **`"user"` schema**: Views used for user sync in the Flutter app (must be quoted as `"user"` in SQL)
- Schema files are organized in subdirectories: `50-tables/`, `60-functions/`, `70-views/`, `90-user-schema/`, `95-triggers/`, etc.

## Rules

- **READONLY**: Only run SELECT queries. Never INSERT, UPDATE, DELETE, DROP, ALTER, or TRUNCATE.
- **No PII in output**: Redact or summarize personal data (emails, names) — show counts and patterns, not raw PII.
- **Limit result sets**: Always use LIMIT (default 100) to avoid pulling large datasets.
- **No schema changes**: This user cannot modify the schema, but don't even attempt it.
- **Performance**: Avoid full table scans on large tables. Check the query plan first if unsure.

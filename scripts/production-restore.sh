#!/usr/bin/env bash
set -euo pipefail

# Restore production data to a new PostgreSQL instance.
# Usage: NEW_DB_URL=postgresql://... ./scripts/production-restore.sh [dump-file]

if [ -z "${NEW_DB_URL:-}" ]; then
  echo "Error: NEW_DB_URL environment variable is required"
  echo "Usage: NEW_DB_URL=postgresql://... $0 [dump-file]"
  exit 1
fi

DUMP_FILE="${1:-production.dump}"

if [ ! -f "$DUMP_FILE" ]; then
  echo "Error: Dump file not found: $DUMP_FILE"
  exit 1
fi

echo "Step 1: Applying migrations..."
libs/db/scripts/apply-migrations.sh "$NEW_DB_URL"

echo "Step 2: Restoring data from $DUMP_FILE..."
pg_restore -d "$NEW_DB_URL" --no-owner --no-acl --data-only "$DUMP_FILE" || true

echo "Step 3: Verifying counts..."
psql "$NEW_DB_URL" -c "
  SELECT 'user' AS entity, count(*) FROM public.\"user\"
  UNION ALL SELECT 'activities', count(*) FROM public.activity
  UNION ALL SELECT 'priorities', count(*) FROM public.priority
  UNION ALL SELECT 'contacts', count(*) FROM public.contact;
"

echo ""
echo "Done. Post-migration steps:"
echo "  1. Update Cloudflare Hyperdrive connection string to new PostgreSQL instance"
echo "  2. Verify API reads/writes work"
echo "  3. Verify user sync triggers fire correctly"

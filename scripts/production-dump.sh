#!/usr/bin/env bash
set -euo pipefail

# Dump production Supabase database (public + user + admin schemas)
# Usage: PRODUCTION_DB_URL=postgresql://... ./scripts/production-dump.sh

if [ -z "${PRODUCTION_DB_URL:-}" ]; then
  echo "Error: PRODUCTION_DB_URL environment variable is required"
  echo "Usage: PRODUCTION_DB_URL=postgresql://... $0"
  exit 1
fi

OUTPUT="${1:-production.dump}"

echo "Dumping production database..."
pg_dump "$PRODUCTION_DB_URL" \
  --schema=public --schema=user --schema=admin \
  --no-owner --no-acl \
  -Fc -f "$OUTPUT"

echo "Done. Output: $OUTPUT"
echo "Size: $(du -h "$OUTPUT" | cut -f1)"

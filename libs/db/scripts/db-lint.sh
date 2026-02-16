#!/usr/bin/env bash
set -e

DB_URL="${1:-${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}}"

echo "Running plpgsql_check on all functions..."

# Run lint and capture output
OUTPUT=$(psql "$DB_URL" -t -A -F $'\t' <<'SQL'
SELECT
  p.oid::regprocedure AS function,
  pc.*
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN LATERAL extensions.plpgsql_check_function(p.oid) pc
WHERE n.nspname IN ('public', 'user')
  AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
  AND p.prorettype != 'trigger'::regtype
ORDER BY 1;
SQL
)

if [ -z "$OUTPUT" ]; then
  echo "No issues found."
  exit 0
fi

# Print all results
echo "$OUTPUT"

# Check for errors (not just warnings)
if echo "$OUTPUT" | grep -q $'\terror:'; then
  echo ""
  echo "❌ plpgsql_check found errors. Fix them before proceeding."
  exit 1
fi

echo ""
echo "Lint passed (warnings only)."

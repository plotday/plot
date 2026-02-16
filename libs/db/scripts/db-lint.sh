#!/usr/bin/env bash
set -e

DB_URL="${1:-${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}}"

echo "Running plpgsql_check on all functions..."
psql "$DB_URL" -v ON_ERROR_STOP=1 <<'SQL'
SELECT
  p.oid::regprocedure AS function,
  pc.*
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN LATERAL plpgsql_check_function(p.oid) pc
WHERE n.nspname = 'public'
  AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
  AND p.prorettype != 'trigger'::regtype
ORDER BY 1;
SQL

echo "Lint complete."

#!/usr/bin/env bash
# Verify the migration directories reproduce the schema source of truth.
# Exits non-zero (and prints the pending diff) if they are out of sync.
#
# With no contract migrations this is exactly the original
# `atlas migrate diff verify_sync --env local`. With contracts present we must
# replay migrations/ + migrations-contract/ TOGETHER, otherwise Atlas sees each
# contract's DROP as a missing change and reports a false diff.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-migrations.sh

if ! has_contracts; then
  exec atlas migrate diff verify_sync --env local
fi

combined="$(build_combined_dir)"
trap 'rm -rf "$combined"' EXIT

before="$(ls "$combined")"
atlas migrate diff verify_sync --env local --dir "file://$combined" >/dev/null 2>&1 || true
newfile="$(comm -13 <(echo "$before" | sort) <(ls "$combined" | sort) | grep -E 'verify_sync\.sql$' || true)"

if [ -n "$newfile" ]; then
  echo "❌ Schema files and migrations are OUT OF SYNC. Pending changes:"
  echo "---"
  cat "$combined/$newfile"
  echo "---"
  echo "Generate the missing migration with 'pnpm gen-migration -- <name>'"
  echo "(or 'pnpm gen-contract-migration -- <name>' if it is destructive)."
  exit 1
fi

echo "✅ Schema files and migrations (expand + contract) are in sync."

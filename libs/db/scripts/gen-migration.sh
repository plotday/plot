#!/usr/bin/env bash
# Generate an EXPAND migration (into migrations/) from schema changes.
# Use this for additive / backward-compatible changes. For destructive cleanup
# (DROP COLUMN/TABLE, rename, type narrowing) use gen-contract-migration.sh —
# the CI destructive-change gate will reject destructive DDL landed here.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-migrations.sh

./scripts/db-lint.sh
# `pnpm gen-migration -- <name>` forwards the `--` separator as $1; drop it.
if [ "${1:-}" = "--" ]; then shift; fi
NAME="${1:-}"

if has_contracts; then
  generate_via_combined "migrations" "$NAME"
else
  # No contracts yet: identical to the original single-dir behavior.
  if [ -n "$NAME" ]; then
    atlas migrate diff "$NAME" --env local
  else
    atlas migrate diff --env local
  fi
fi

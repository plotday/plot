#!/usr/bin/env bash
# Generate a CONTRACT migration (into migrations-contract/) — the destructive
# cleanup half of an expand/contract change. ONLY run this once the workers that
# stopped using the column/table have already shipped in a prior deploy; the
# contract drains at the start of a later deploy (scripts/drain-contracts.sh).
#
# Workflow:
#   1. Remove the column/table from schema/ (the source of truth).
#   2. pnpm gen-contract-migration -- drop_old_thing
#   3. pnpm apply-migrations   (applies it locally so your dev DB matches)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-migrations.sh

./scripts/db-lint.sh
# `pnpm gen-contract-migration -- <name>` forwards the `--` separator as $1; drop it.
if [ "${1:-}" = "--" ]; then shift; fi
generate_via_combined "${CONTRACT_DIR}" "${1:-}"

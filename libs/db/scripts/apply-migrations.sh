#!/usr/bin/env bash
# Apply all pending migrations to the LOCAL database, then lint + regen types.
# Applies the expand dir (migrations/) and then, if any exist, the contract dir
# (migrations-contract/) so the local dev DB always matches the final schema.
# In production the contract dir drains gradually instead — see
# scripts/drain-contracts.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-migrations.sh

URL="$(local_db_url)"

./scripts/init-local-roles.sh

# Expand migrations. --exec-order non-linear so a migration whose timestamp is
# behind the latest already-applied version still applies instead of hard-erroring.
# Concurrent PRs/worktrees routinely merge migrations whose timestamps interleave
# (e.g. PR A authored at 14:08 merges *after* PR B authored at 15:52), and the
# default "linear" mode aborts on the older file. This is safe because the schema
# files remain the source of truth: CI replays the full set on a fresh DB in
# canonical filename order and fails if the committed types don't match, so a
# differing apply order on an existing DB never changes the verified end state. A
# genuinely conflicting migration still fails loudly (SQL error, transactional
# rollback) rather than silently drifting. Do NOT use "linear-skip" — it silently
# skips the out-of-order file so it never applies at all.
atlas migrate apply --env local --url "$URL" --exec-order non-linear

# Contract migrations, on their own independent revisions schema. --allow-dirty
# because the database legitimately already contains the expand schema (the
# contract revisions table is separate and starts empty).
if has_contracts; then
  atlas migrate apply \
    --dir "file://${CONTRACT_DIR}" \
    --revisions-schema "${CONTRACT_REVISIONS_SCHEMA}" \
    --allow-dirty \
    --exec-order non-linear \
    --url "$URL"
fi

./scripts/db-lint.sh
pnpm run types:if-local

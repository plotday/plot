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

# Expand migrations (unchanged from the original single-dir behavior).
atlas migrate apply --env local --url "$URL"

# Contract migrations, on their own independent revisions schema. --allow-dirty
# because the database legitimately already contains the expand schema (the
# contract revisions table is separate and starts empty).
if has_contracts; then
  atlas migrate apply \
    --dir "file://${CONTRACT_DIR}" \
    --revisions-schema "${CONTRACT_REVISIONS_SCHEMA}" \
    --allow-dirty \
    --url "$URL"
fi

./scripts/db-lint.sh
pnpm run types:if-local

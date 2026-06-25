#!/usr/bin/env bash
# Drain SOAKED contract migrations against the target database (production).
#
# Run at the START of a deploy, before the expand migrations apply and before
# workers deploy. It applies only contract migrations that have already SOAKED —
# i.e. were committed before the previous deploy, so the workers that stopped
# using the dropped column have been live since that deploy. Contracts added in
# the current batch (newer than the previous deploy tag) are left pending and
# drain at the NEXT deploy. This preserves a rollback window and never drops a
# column the currently-live workers still use.
#
# Idempotent; a no-op when nothing has soaked. Requires:
#   MIGRATE_URL  — target database URL (with sslmode as needed)
#   full git history with deploy/<YYYYMMDD.HHMMSS> tags (fetch-depth: 0)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-migrations.sh

URL="${MIGRATE_URL:?MIGRATE_URL must be set to the target database URL}"

if ! has_contracts; then
  echo "No contract migrations present; nothing to drain."
  exit 0
fi

# Boundary = the most recent deploy tag. This runs before the current deploy's
# tag is created, so the latest existing tag is the PREVIOUS deploy.
prev_tag="$(git tag -l 'deploy/*' --sort=-creatordate | head -n1 || true)"
if [ -z "$prev_tag" ]; then
  echo "No previous deploy tag found; no contracts have soaked yet. Skipping drain."
  exit 0
fi
# deploy/20260602.150000 -> 20260602150000 (matches the migration version)
boundary="$(echo "$prev_tag" | sed -E 's@^deploy/@@; s@\.@@')"
echo "Previous deploy tag: $prev_tag  (soak boundary version: $boundary)"

# Contract versions already applied (the revisions table may not exist on the
# very first drain).
applied="$(psql "$URL" -tAc \
  "SELECT version FROM ${CONTRACT_REVISIONS_SCHEMA}.atlas_schema_revisions" 2>/dev/null || true)"

# Highest contract version that is still pending AND soaked (<= boundary).
# Files iterate in version order, so the loop ends on the newest such version;
# --to-version then applies the whole soaked-and-pending prefix.
target=""
for f in "${CONTRACT_DIR}"/*.sql; do
  ver="$(basename "$f" | sed -E 's@_.*@@')"
  if printf '%s\n' "$applied" | grep -qxF "$ver"; then
    continue   # already applied
  fi
  if [ "$ver" -le "$boundary" ]; then
    target="$ver"
  fi
done

if [ -z "$target" ]; then
  echo "No soaked, un-applied contract migrations to drain."
  exit 0
fi

echo "Draining contract migrations up to version $target ..."
# --exec-order non-linear matches the expand apply: a soaked contract whose
# timestamp landed behind an already-drained one still applies instead of
# aborting. --to-version still caps the set to soaked migrations, so non-linear
# only relaxes ordering among files at or below the target, never drains an
# unsoaked contract.
atlas migrate apply \
  --dir "file://${CONTRACT_DIR}" \
  --revisions-schema "${CONTRACT_REVISIONS_SCHEMA}" \
  --allow-dirty \
  --exec-order non-linear \
  --to-version "$target" \
  --url "$URL"

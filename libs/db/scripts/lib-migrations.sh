#!/usr/bin/env bash
# Shared helpers for the two-directory migration layout.
#
# Plot uses two Atlas migration directories:
#   migrations/           — "expand" migrations. Append-only, backward-compatible
#                           with the currently-deployed workers. Applied before
#                           workers deploy. This is the original directory; when
#                           migrations-contract/ is empty the tooling behaves
#                           exactly as it always did (single-dir).
#   migrations-contract/  — "contract" migrations. The destructive cleanup half
#                           of an expand/contract change (DROP COLUMN, etc.).
#                           Tracked in a SEPARATE Atlas revisions schema
#                           (atlas_contract) so its history is independent of the
#                           expand history — a pending/aborted contract can never
#                           block a future expand. In production these drain at
#                           the START of a later deploy, once the workers that
#                           stopped using the column have already shipped
#                           (see scripts/drain-contracts.sh). Locally we apply
#                           them immediately so the dev DB matches the final
#                           schema.
#
# See libs/db/AGENTS.md "Production Migration Safety" and
# docs/superpowers/specs/2026-06-02-zero-downtime-deploy-design.md.

CONTRACT_DIR="migrations-contract"
CONTRACT_REVISIONS_SCHEMA="atlas_contract"

# True when at least one contract migration exists. When false, callers fall
# back to the original single-directory behavior.
has_contracts() {
  compgen -G "${CONTRACT_DIR}/*.sql" >/dev/null 2>&1
}

# Build a temporary directory merging both migration dirs (by Atlas version /
# timestamp order, which file names already encode) and print its path. Used as
# the diff baseline so we never regenerate a drop that already lives in the
# contract dir. Caller is responsible for `rm -rf`.
build_combined_dir() {
  local combined
  combined="$(mktemp -d)"
  cp migrations/*.sql "$combined"/ 2>/dev/null || true
  cp "${CONTRACT_DIR}"/*.sql "$combined"/ 2>/dev/null || true
  atlas migrate hash --dir "file://$combined" >/dev/null
  echo "$combined"
}

# Resolve the local database URL the same way the original package scripts did.
local_db_url() {
  echo "${DATABASE_URL:-postgres://postgres:postgres@127.0.0.1:54322/postgres}?sslmode=disable"
}

# Generate a migration from the schema source into <target_dir>, using a merged
# (expand + contract) baseline so already-contracted drops are not regenerated.
# The destructive-change CI gate decides whether the result belongs in
# migrations/ or migrations-contract/; this just routes to the chosen dir.
#   generate_via_combined <target_dir> [name]
generate_via_combined() {
  local target="$1"; shift
  local name="${1:-}"
  local combined; combined="$(build_combined_dir)"
  # shellcheck disable=SC2064
  trap "rm -rf '$combined'" RETURN

  local before; before="$(ls "$combined")"
  if [ -n "$name" ]; then
    atlas migrate diff "$name" --env local --dir "file://$combined"
  else
    atlas migrate diff --env local --dir "file://$combined"
  fi

  local newfile
  newfile="$(comm -13 <(echo "$before" | sort) <(ls "$combined" | sort) | grep -E '\.sql$' || true)"
  if [ -z "$newfile" ]; then
    echo "No schema changes to generate."
    return 0
  fi

  mkdir -p "$target"
  mv "$combined/$newfile" "$target/"
  atlas migrate hash --dir "file://$target"
  echo "Generated $target/$newfile"
}

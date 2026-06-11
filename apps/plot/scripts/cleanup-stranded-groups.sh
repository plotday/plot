#!/usr/bin/env bash
# One-off cleanup for stranded duplicate groups in local Plot client DBs.
#
# Background: the dev seed generator (libs/db/seeds/generate-seed.ts) used to
# create groups with a fresh random UUID on every run while bare-DELETEing the
# old rows server-side. `group` is a synced table, so the bare DELETE never
# reached Flutter clients — every reseed stranded the prior run's group rows
# locally, accumulating duplicates (e.g. 11x "Coaching staff") that show a
# 0 member count because their members point at long-gone contacts.
#
# The seed is now fixed (deterministic group ids), so this only needs to run
# once to purge the already-stranded copies from existing local DBs.
#
# Strategy: within each plot-*.sqlite, for every PRIVATE group whose name is
# duplicated, keep the single most-recently-updated row and delete the rest.
# Run AFTER reseeding against the fixed seed so the kept row is the canonical
# (freshly-synced) one; running before reseed still collapses N copies to 1.
#
# Usage:
#   apps/plot/scripts/cleanup-stranded-groups.sh           # dry run (default)
#   apps/plot/scripts/cleanup-stranded-groups.sh --apply   # actually delete
set -euo pipefail

DOCS="$HOME/Library/Containers/day.plot.app/Data/Documents"
APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

# Groups to consider: user-created private groups (the seed inserts type
# 'private'). System groups (Plot Team) are type 'announce'/'team', so this
# scope already excludes them — and it avoids the older `key` column some
# legacy profile DBs don't have.
SCOPE="type = 'private'"

# Single-column subquery (no trailing ';') of the ids to delete: every
# duplicate-name private group except the newest per name.
victims_ids() {
  cat <<SQL
WITH ranked AS (
  SELECT id,
    ROW_NUMBER() OVER (PARTITION BY name ORDER BY updated_at DESC, hex(id)) AS rn,
    COUNT(*)     OVER (PARTITION BY name)                                  AS cnt
  FROM groups
  WHERE $SCOPE
)
SELECT id FROM ranked WHERE cnt > 1 AND rn > 1
SQL
}

shopt -s nullglob
total=0
for db in "$DOCS"/plot-*.sqlite; do
  # Skip DBs without a groups table (very old / empty profiles).
  sqlite3 "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='groups';" \
    | grep -q 1 || continue

  count=$(sqlite3 "$db" "SELECT COUNT(*) FROM ($(victims_ids));")
  [[ "$count" == "0" ]] && continue

  echo "=== ${db##*/} : $count stranded duplicate group row(s) ==="
  echo "    duplicate names (kept = 1 newest per name):"
  sqlite3 -column "$db" \
    "SELECT name, COUNT(*) AS total FROM groups WHERE $SCOPE GROUP BY name HAVING total > 1;" \
    | sed 's/^/      /'

  if [[ $APPLY -eq 1 ]]; then
    sqlite3 "$db" "DELETE FROM groups WHERE id IN ($(victims_ids));"
    echo "    -> deleted $count row(s)."
  fi
  total=$((total + count))
  echo
done

if [[ $APPLY -eq 1 ]]; then
  echo "Done. Removed $total stranded duplicate group row(s)."
  echo "Restart the app (or hot-restart) so the picker reloads from the DB."
else
  echo "DRY RUN — found $total stranded duplicate group row(s) across all DBs."
  echo "Re-run with --apply to delete them."
fi

#!/usr/bin/env bash
# One-shot recovery: rewrite Storage DO keys for a LinkedIn auth so they
# move from a synthetic actorId (the orphan UUID buildActor() creates
# when providerData lacks both email and providerUserId) to the user's
# real contact id. Required when onAuth ran with providerData=null
# before the parseTokenResponse fix landed.
#
# Usage:
#   scripts/relink-linkedin-actor.sh <do-sqlite-file> <synthetic-actorId> <real-contact-id>
#
# Find the DO file:
#   for f in workers/api/.wrangler/state/v3/do/api-development-Storage/*.sqlite; do
#     sqlite3 "$f" "SELECT key FROM store WHERE key LIKE 'auth_token:linkedin:%' LIMIT 1;" 2>/dev/null \
#       | grep -q . && echo "$f"
#   done

set -euo pipefail

if [ $# -ne 3 ]; then
  echo "Usage: $0 <do-sqlite> <synthetic-actorId> <real-contactId>" >&2
  exit 1
fi

DO="$1"
SYNTH="$2"
REAL="$3"

echo "BEFORE:"
sqlite3 "$DO" "SELECT key FROM store WHERE key LIKE '%:linkedin:${SYNTH}';"

sqlite3 "$DO" "
BEGIN;
UPDATE store SET key = REPLACE(key, '${SYNTH}', '${REAL}') WHERE key LIKE '%:linkedin:${SYNTH}';
COMMIT;
"

echo "AFTER:"
sqlite3 "$DO" "SELECT key FROM store;"

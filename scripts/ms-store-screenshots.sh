#!/usr/bin/env bash
#
# Push the committed Windows Store screenshots onto the CURRENT pending Microsoft
# Store submission via the Submission REST API. `msstore` has no image command
# and updateMetadata is text-only, so screenshots must go through the raw API.
#
# Used by the release workflow's "Upload screenshots to Microsoft Store" step
# (gated on the update_screenshots input), AFTER `msstore publish --noCommit`
# has created the draft and uploaded the package. It does NOT commit — the
# workflow's "Submit ... for review" step (or Partner Center) does that.
#
# Auth:
#   - CI: AZURE_AD_TENANT_ID / AZURE_AD_APPLICATION_CLIENT_ID /
#     AZURE_AD_APPLICATION_SECRET (the same secrets msstore uses).
#   - Local: falls back to `op read` from 1Password (run `eval $(op signin)`).
#
# Idempotent: existing images are preserved by Id, the repo set is added only if
# absent, everything else is marked PendingDelete. The package already uploaded
# into the submission's fileUploadUrl blob is preserved — the new screenshots are
# APPENDED to that blob, never replacing it (the blob is replaced whole on PUT).
#
# Needs: jq, curl, zip, unzip.
set -uo pipefail

APP_ID="${MS_STORE_PRODUCT_ID:-9PKTCSN8SNZF}"
BASE="https://manage.devcenter.microsoft.com/v1.0/my/applications/$APP_ID"
ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
SHOTS_DIR="${MS_STORE_SHOTS_DIR:-$ROOT/apps/plot/screenshots/store/ms-store/windows}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Auth ---------------------------------------------------------------------
if [ -n "${AZURE_AD_TENANT_ID:-}" ]; then
  TENANT="$AZURE_AD_TENANT_ID"
  CLIENT="$AZURE_AD_APPLICATION_CLIENT_ID"
  SECRET="$AZURE_AD_APPLICATION_SECRET"
else
  command -v op >/dev/null 2>&1 || die "No Azure env vars and no 'op' CLI for local auth."
  op whoami >/dev/null 2>&1 || die "1Password not signed in. Run: eval \$(op signin)"
  TENANT="$(op read 'op://Production/Windows Store/Tenant ID')"
  CLIENT="$(op read 'op://Production/Windows Store/App client ID')"
  SECRET="$(op read 'op://Production/Windows Store/password')"
fi
TOKEN="$(curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  -d grant_type=client_credentials --data-urlencode "client_id=$CLIENT" \
  --data-urlencode "client_secret=$SECRET" \
  --data-urlencode "scope=https://manage.devcenter.microsoft.com/.default" | jq -r .access_token)"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || die "Token fetch failed."
AUTH=(-H "Authorization: Bearer $TOKEN")

# --- Locate the repo screenshots ----------------------------------------------
shopt -s nullglob
SHOTS=( "$SHOTS_DIR"/*.png )
[ "${#SHOTS[@]}" -gt 0 ] || die "No screenshots found under $SHOTS_DIR"
SHOT_NAMES=()
for p in "${SHOTS[@]}"; do SHOT_NAMES+=( "$(basename "$p")" ); done
KEEP_JSON="$(printf '%s\n' "${SHOT_NAMES[@]}" | jq -R . | jq -s .)"
echo "Repo screenshots (${#SHOTS[@]}): ${SHOT_NAMES[*]}"

# --- Find the pending submission ----------------------------------------------
SUB_ID="$(curl -s "${AUTH[@]}" "$BASE" | jq -r '.pendingApplicationSubmission.id // empty')"
[ -n "$SUB_ID" ] || die "No pending submission — run the package publish step first."
echo "Pending submission: $SUB_ID"
curl -s "${AUTH[@]}" "$BASE/submissions/$SUB_ID" > "$TMP/sub.json"
UPLOAD_URL="$(jq -r '.fileUploadUrl' "$TMP/sub.json")"
[ -n "$UPLOAD_URL" ] && [ "$UPLOAD_URL" != "null" ] || die "Submission has no fileUploadUrl."

LANG_KEY="$(jq -r '(.listings // {}) as $l | ([$l|keys[]|select(test("^en";"i"))][0]) // ($l|keys[0]) // empty' "$TMP/sub.json")"
[ -n "$LANG_KEY" ] || die "No listing language on the submission."
echo "Listing language: $LANG_KEY"

# --- Idempotent image rewrite -------------------------------------------------
jq --arg k "$LANG_KEY" --argjson keep "$KEEP_JSON" '
    (.listings[$k].baseListing.images // []) as $imgs
  | ($imgs | map(.fileName)) as $present
  | .listings[$k].baseListing.images =
      (($imgs | map(if ((.fileName) as $f | $keep | index($f)) != null then . else (.fileStatus="PendingDelete") end))
       + ($keep | map(select((. as $f | $present | index($f)) == null))
               | map({fileName:., fileStatus:"PendingUpload", imageType:"Screenshot"})))
' "$TMP/sub.json" > "$TMP/sub-desired.json"

CODE="$(curl -s -o "$TMP/put.json" -w "%{http_code}" -X PUT "${AUTH[@]}" \
  -H "Content-Type: application/json" --data @"$TMP/sub-desired.json" "$BASE/submissions/$SUB_ID")"
[ "$CODE" = "200" ] || { cat "$TMP/put.json" >&2; die "PUT submission failed (HTTP $CODE)."; }

# --- Files that still need bytes uploaded -------------------------------------
PENDING_IMGS="$(jq -r --arg k "$LANG_KEY" \
  '.listings[$k].baseListing.images | map(select(.fileStatus=="PendingUpload") | .fileName) | .[]' "$TMP/put.json")"
PKG_PENDING="$(jq '[.applicationPackages[]? | select(.fileStatus=="PendingUpload")] | length' "$TMP/put.json")"

if [ -z "$PENDING_IMGS" ]; then
  echo "All repo screenshots already present on the submission — nothing to upload."
else
  # Preserve the package: download the existing blob (which holds the MSIX that
  # msstore publish uploaded) and APPEND the screenshots to it.
  curl -s -o "$TMP/blob.zip" "$UPLOAD_URL"
  if unzip -l "$TMP/blob.zip" >/dev/null 2>&1; then
    echo "Appending screenshots to the existing package blob."
  else
    # No usable existing blob. Only safe to start a fresh one if there is no
    # pending package that would be orphaned by replacing the blob.
    [ "$PKG_PENDING" = "0" ] || die "Existing upload blob is unreadable but a package is pending — refusing to clobber it."
    echo "No existing blob; creating a screenshots-only bundle."
    rm -f "$TMP/blob.zip"
  fi
  while IFS= read -r fn; do
    [ -z "$fn" ] && continue
    [ -f "$SHOTS_DIR/$fn" ] || die "Pending image '$fn' has no local source in $SHOTS_DIR."
    zip -j -q "$TMP/blob.zip" "$SHOTS_DIR/$fn"
  done <<< "$PENDING_IMGS"

  UP="$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    -H "x-ms-blob-type: BlockBlob" --data-binary @"$TMP/blob.zip" "$UPLOAD_URL")"
  [ "$UP" = "201" ] || die "Blob upload failed (HTTP $UP, expected 201)."
  echo "Uploaded $(printf '%s\n' "$PENDING_IMGS" | grep -c .) screenshot(s) into the submission blob."
fi

# --- Report -------------------------------------------------------------------
curl -s "${AUTH[@]}" "$BASE/submissions/$SUB_ID" \
  | jq --arg k "$LANG_KEY" '{status, errors: .statusDetails.errors,
      images: (.listings[$k].baseListing.images | map({fileName, fileStatus}))}'
echo "Screenshots staged on submission $SUB_ID (not committed)."

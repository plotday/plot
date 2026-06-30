#!/usr/bin/env bash
# Deploy the marketing site as a NON-LIVE version, smoke-test its preview URL,
# and only promote to 100% if it's healthy. A bundle that crashes the worker at
# module init (the vite 8.1.0 Clerk `setErrorThrowerOptions` class of bug) is
# caught on the preview URL and never serves production — the previously-live
# version keeps serving until a healthy one is promoted.
#
# Why a preview gate in addition to the PR build-boot gate: this runs the ACTUAL
# version about to take traffic, with REAL production secrets/bindings, so it
# also catches crashes that only manifest with prod config (a missing secret, a
# bad var) which the local PR boot — running on placeholders — can't see.
#
# Inherited behaviour from the old `nx deploy:site`:
#   - if DEPLOY_VARS is set, pass them as --var (else --keep-vars)
#   - secrets were already pushed by the caller (`wrangler secret bulk`); a
#     `versions upload` inherits the worker's existing secrets by default.
#
# Run from the apps/site directory. Requires CLOUDFLARE_API_TOKEN / _ACCOUNT_ID
# in the environment and VERSION_TAG (a unique label for this run, e.g. the CI
# run id). Fails closed: any parse/smoke failure aborts BEFORE promotion.
set -euo pipefail

: "${VERSION_TAG:?VERSION_TAG must be set (a unique tag for this upload)}"
OUT="$(mktemp)"

# Mirror the old deploy script's var handling.
upload_args=(--tag "$VERSION_TAG" --message "CI ${VERSION_TAG}")
if [ -n "${DEPLOY_VARS:-}" ]; then
  # shellcheck disable=SC2206  # intentional word-splitting: DEPLOY_VARS is a list
  upload_args+=(--var ${DEPLOY_VARS})
else
  upload_args+=(--keep-vars)
fi

echo "==> Uploading new (non-live) version..."
pnpm exec wrangler versions upload "${upload_args[@]}" 2>&1 | tee "$OUT"

# Parse the preview URL and version id from the upload output. Fail closed if
# either is missing (a wrangler output-format change must block promotion, not
# silently ship an unverified version).
PREVIEW_URL="$(grep -iE 'preview url' "$OUT" | grep -oE 'https://[^[:space:]]+' | head -1 || true)"
VERSION_ID="$(grep -ioE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$OUT" | head -1 || true)"

if [ -z "$PREVIEW_URL" ]; then
  echo "::error::Could not parse a preview URL from 'wrangler versions upload' output — refusing to promote. Is workers_dev/preview-urls enabled?"
  exit 1
fi
if [ -z "$VERSION_ID" ]; then
  echo "::error::Could not parse the version id from 'wrangler versions upload' output — refusing to promote."
  exit 1
fi
echo "==> Uploaded version $VERSION_ID"
echo "==> Preview URL: $PREVIEW_URL"

# Give the preview a moment to propagate, then smoke it. Worker-health only
# (--no-status-check): on a workers.dev preview host Clerk may render a non-200,
# which is NOT a worker crash; only an x-plot-error / crash marker fails this.
echo "==> Waiting for preview to respond..."
ready=false
for _ in $(seq 1 30); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$PREVIEW_URL/" 2>/dev/null || true)"
  if printf '%s' "$code" | grep -qE '^[1-5][0-9][0-9]$'; then ready=true; break; fi
  sleep 2
done
if [ "$ready" != true ]; then
  echo "::error::preview URL never responded — refusing to promote."
  exit 1
fi

echo "==> Smoke-testing preview..."
if ! node scripts/smoke-test-site.mjs --url "$PREVIEW_URL" --no-status-check; then
  echo "::error::Preview smoke test failed — the new version crashes the worker. NOT promoting; the previously-live version keeps serving."
  exit 1
fi

echo "==> Smoke passed. Promoting version $VERSION_ID to 100%..."
pnpm exec wrangler versions deploy "$VERSION_ID@100%" --yes --message "CI ${VERSION_TAG} (smoke-passed)"
echo "==> Done."

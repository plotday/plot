#!/usr/bin/env bash
# Submit (commit) a Microsoft Store submission for Plot (product 9PKTCSN8SNZF).
#
# Usage:
#   ms-store-submit.sh                 # commit the existing pending draft
#   ms-store-submit.sh 1.5.0+373       # download that release's MSIX, create a
#                                      # fresh submission with it, and commit
#
# Requires `msstore` to be installed and already configured via
# `msstore reconfigure` (the caller does this with the Azure AD secrets).
set -euo pipefail

PRODUCT_ID="9PKTCSN8SNZF"
VERSION="${1:-}"
R2_PUBLIC_BASE="${R2_PUBLIC_BASE:-https://download.plot.day}"

if [ -n "$VERSION" ]; then
  MSIX_FILE="Plot-${VERSION}.msix"
  URL="${R2_PUBLIC_BASE}/releases/${VERSION}/windows/${MSIX_FILE}"
  echo "Downloading ${URL}"
  curl -fSL "$URL" -o "$MSIX_FILE"
  # publish WITHOUT --noCommit creates a new submission AND commits it for
  # certification in one step. msstore deletes any existing pending draft first.
  msstore publish "$MSIX_FILE" -id "$PRODUCT_ID" --verbose
else
  echo "Committing existing pending submission for ${PRODUCT_ID}"
  msstore submission publish "$PRODUCT_ID"
fi

echo "Microsoft Store submission committed."

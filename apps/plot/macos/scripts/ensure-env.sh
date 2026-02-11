#!/bin/sh
set -e
PLOT_DIR="$(cd "$PROJECT_DIR/.." && pwd)"

case "$CONFIGURATION" in
  Release|Profile) DESIRED=".env.production" ;;
  *) DESIRED=".env.development" ;;
esac

if [ ! -f "$PLOT_DIR/$DESIRED" ]; then
  echo "error: $PLOT_DIR/$DESIRED not found. Run 'pnpm get-env' in apps/plot/ first." >&2
  exit 1
fi

CURRENT=$(readlink "$PLOT_DIR/.env" 2>/dev/null || echo "")
if [ "$CURRENT" != "$DESIRED" ]; then
  echo "note: Switching .env: ${CURRENT:-<missing>} -> $DESIRED ($CONFIGURATION)"
  rm -f "$PLOT_DIR/.env"
  ln -s "$DESIRED" "$PLOT_DIR/.env"
fi

if [ "$DESIRED" = ".env.production" ] && grep -q 'localhost\|127\.0\.0\.1' "$PLOT_DIR/$DESIRED"; then
  echo "error: Production .env contains localhost URLs!" >&2
  exit 1
fi

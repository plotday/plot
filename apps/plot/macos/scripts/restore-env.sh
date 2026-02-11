#!/bin/sh
PLOT_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
CURRENT=$(readlink "$PLOT_DIR/.env" 2>/dev/null || echo "")
if [ "$CURRENT" != ".env.development" ] && [ -f "$PLOT_DIR/.env.development" ]; then
  echo "note: Restoring .env to .env.development"
  rm -f "$PLOT_DIR/.env"
  ln -s ".env.development" "$PLOT_DIR/.env"
fi
exit 0

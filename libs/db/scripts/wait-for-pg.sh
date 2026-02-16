#!/usr/bin/env bash
set -e

HOST="${1:-127.0.0.1}"
PORT="${2:-54322}"
MAX_WAIT=30

echo "Waiting for PostgreSQL on ${HOST}:${PORT}..."
for i in $(seq 1 $MAX_WAIT); do
  if pg_isready -h "$HOST" -p "$PORT" -U postgres > /dev/null 2>&1; then
    echo "PostgreSQL is ready."
    exit 0
  fi
  sleep 1
done

echo "Timed out waiting for PostgreSQL after ${MAX_WAIT}s"
exit 1

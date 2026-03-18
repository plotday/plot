#!/bin/bash
# Mints a fresh session JWT for plot.test.1 and calls the test push endpoint.
# Usage: bash scripts/trigger-push-test.sh

set -e

CLERK_SECRET="sk_test_3T4rEb9eAEaypQIUZYyYHMT6cyajuvbm6MWT5o3Gok"
SESSION_ID="sess_3B8KiFNxJDdfimDRV46RDjURb24"
API="http://localhost:8787/app"

echo "Minting fresh JWT..."
JWT=$(curl -s -X POST "https://api.clerk.com/v1/sessions/$SESSION_ID/tokens" \
  -H "Authorization: Bearer $CLERK_SECRET" \
  -H "Content-Type: application/json" | python3 -c "import sys,json; print(json.load(sys.stdin)['jwt'])")

echo "Triggering push..."
curl -s -X POST "$API/test/trigger-push" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -m json.tool

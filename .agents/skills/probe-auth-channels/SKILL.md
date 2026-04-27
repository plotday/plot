---
name: probe-auth-channels
description: Trigger an on-demand sweep of every active connection's auth token in production (or local). Use when the user asks to detect broken syncs, flag re-auth, force the channel refresh, or check how many connections have stale auth without waiting for the daily 05:00 UTC cron.
---

# Probe Auth Channels (on-demand refreshAllChannels)

`POST /admin/refresh-channels` re-runs the same daily sweep that the cron runs at 05:00 UTC. It iterates every active `twist_instance_connection` and calls `refreshChannels` per row, which flows through `getActorToken`. Any connection whose token is permanently broken gets `twist_instance_connection.needs_reauth_at` set as a side effect, and the user gets a sync push so the app can prompt re-auth.

Use this when waiting until tomorrow's 01:00 EDT cron is too slow.

## Step 1: Pick the environment

| Env | Base URL |
|---|---|
| Local dev | `http://localhost:8787` |
| Production | `https://api.plot.day` |

For local, the API worker has to be running: `pnpm --filter @plotday/api dev`.

## Step 2: Get the bearer token

The endpoint reads `ADMIN_API_KEY` from the worker's environment. If the user hasn't set one yet, tell them to:

1. Add `ADMIN_API_KEY=<random hex>` to the relevant root `.env` file (`.env.development` for local dev, `.env.production` for prod). Use a 32-byte secret: `openssl rand -hex 32`.
2. Run `pnpm --filter @plotday/api get-env` so it lands in `workers/api/.dev.vars`.
3. For prod, `pnpm --filter @plotday/api set-env production` (or however prod secrets are pushed).

Then read the value back when you need it (don't print it):

```bash
ADMIN_API_KEY=$(grep '^ADMIN_API_KEY=' workers/api/.dev.vars | cut -d= -f2-)
```

If the variable is missing or empty, the endpoint returns `503 {"error":"Admin API not configured"}` — that's the signal to set it up.

## Step 3: Trigger the sweep

```bash
curl -sS -X POST \
  -H "Authorization: Bearer $ADMIN_API_KEY" \
  https://api.plot.day/admin/refresh-channels
```

Successful response:

```json
{ "ok": true, "durationMs": 12450 }
```

The call is synchronous — it returns once every connection has been probed (~typical 10–30s for a small fleet). It can take longer if a provider is slow; the per-row failures are caught and logged, so one bad connection does not block the rest.

## Step 4: Verify what got flagged

After the sweep returns, query the prod DB (uses the `prod-db-investigate` skill conventions):

```bash
psql -h 127.0.0.1 -p 5433 -U readonly -d plot <<'SQL'
SELECT
  tic.provider,
  COUNT(*)                 AS connections,
  COUNT(DISTINCT user_id)  AS users
FROM twist_instance_connection tic
WHERE needs_reauth_at IS NOT NULL
GROUP BY provider
ORDER BY connections DESC;
SQL
```

For a per-user breakdown:

```bash
psql -h 127.0.0.1 -p 5433 -U readonly -d plot <<'SQL'
SELECT
  u.email,
  tic.provider,
  tic.needs_reauth_at,
  ti.id AS twist_instance_id
FROM twist_instance_connection tic
JOIN "user" u ON u.id = tic.user_id
JOIN twist_instance ti ON ti.id = tic.twist_instance_id
WHERE tic.needs_reauth_at IS NOT NULL
ORDER BY tic.needs_reauth_at DESC
LIMIT 100;
SQL
```

## Rules

- **Authorize first.** Never run this against production without explicit user approval — it makes outbound calls to every connected provider and posts sync notifications to every flagged user. Confirm before triggering prod.
- **Don't print the bearer token.** Read it from env into a shell variable and reference it; never echo it back to the user or paste it into chat.
- **Idempotent but not free.** Repeated calls cost provider quota. Don't loop it; one shot per investigation is enough.
- **Local dev is safe to spam.** Use it freely while iterating on the flagging logic.

## Implementation reference

- Endpoint: `workers/api/src/app/admin.ts`
- Underlying sweep: `workers/api/src/scheduled/refresh-channels.ts` (`refreshAllChannels`)
- Flagging side-effect: `workers/api/src/twist/tools/integrations.ts` (`flagNeedsReauth`)
- Cron schedule (daily fallback): `workers/api/src/index.ts` — gated to UTC hour 5, minutes 0–4

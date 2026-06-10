# Git-Driven Connector Publishing

**Date:** 2026-06-10
**Status:** Approved (design)

## Problem

Making a connector available to end users in production is currently a manual,
DB-editing chore, and it does not work at all for private connectors.

Two independent gaps:

1. **CI never deploys private connectors.** `.github/workflows/deploy-twists.yml`
   discovers connectors by globbing only `public/connectors/*/package.json`
   (lines 167–174) and resolves the package from
   `public/connectors/$CONNECTOR/package.json` (line 415). Private connectors in
   `connectors/` at the repo root (`linkedin`, `instagram`, `whatsapp`) are
   invisible to it — they are never auto-deployed.

2. **Reaching `public` requires touching the DB.** End users only see twist rows
   where `environment = 'public'` (`workers/api/src/app/account.ts:112,557`,
   `invitation.ts:479`). The CLI can deploy to `personal | private | review`;
   `public` is reached only when a `review` row's `auto_approve` is `true`
   (`workers/api/src/twist/deployment.ts:430`). But nothing in the current code
   sets `auto_approve` — its only setter was the `twist_admin` table, dropped in
   migration `20260416152401`. So in prod the flag is maintained by hand, directly
   in the DB. There is also a dev-only direct-to-public shortcut
   (`sdk/twist.ts:396-419`, gated on `ENV === "development"` + `@plot.day` email)
   that is always `403` in prod (`ENV = "production"`, `wrangler.jsonc:358`).

### Motivating case: LinkedIn

LinkedIn (`connectors/linkedin`, private, `plotTwistId
4e6a959d-ebe2-4a85-bd06-ec46fbac204a`) needs to go public. Prod state today
(verified via readonly DB):

- A `review` row exists, `auto_approve = f`, **no `public` row** → invisible to
  users.
- Its version is `1779370740107` (far older than the freshly-deployed connectors
  at `1781099…`) and `premium = f` despite being in `PREMIUM_TWIST_PACKAGE_IDS` —
  it was hand-deployed once long ago and never refreshed.
- 1 `review` twist_instance, 0 public.

## Goals

- Deploy private connectors (`connectors/*`) through CI, same as public ones.
- Make "which connectors are public" a git-tracked list in the private repo, so
  promotion is a reviewable code change — no DB edits, no API redeploy.
- Authorize public deploys in prod with a token-level grant validated against the
  DB, replacing the dev-only `@plot.day` shortcut.

## Non-goals

- Unifying the marketing list in `apps/site/app/data/connections.ts` with the
  manifest (stays a separate, manually-maintained list).
- Reworking **twist** promotion. Twists keep the existing
  `review` → `auto_approve` → `public` flow. The `auto_approve` column and the
  promotion block in `deployment.ts:430` therefore stay.
- Dropping the `auto_approve` column.

## Design

### 1. Manifest — `connectors/deploy.json`

A single git file in the private repo, the source of truth for which connectors
are public. Lists public connectors by package name. **Anything not listed
deploys to `review`** (safe default — a new or forgotten connector never
accidentally goes public).

```json
{
  "public": [
    "@plotday/connector-slack",
    "@plotday/connector-gmail",
    "@plotday/connector-google-calendar",
    "@plotday/connector-linkedin"
  ]
}
```

Promotion = add the package name + run the deploy workflow. Demotion = remove it
(the connector's next deploy lands in `review`; an already-published `public` row
is not auto-removed — see Open Questions).

Scope is **connectors only**. The manifest does not govern twists.

### 2. CI deploy support for private connectors

Changes to `.github/workflows/deploy-twists.yml`:

- **Discovery** (lines 167–174): scan **both** `public/connectors/*` and
  `connectors/*` for a `package.json` containing `plotTwistId`, mirroring how the
  twist discovery already scans `twists/*` + `public/twists/*` (line 160). The
  connector matrix carries the directory path (not just the basename) so the
  later steps can locate the package and so a private/public name collision can't
  silently pick the wrong one.
- **Locate** (line 415): resolve the connector directory from either
  `connectors/$CONNECTOR` or `public/connectors/$CONNECTOR`, mirroring the twist
  job's locate step (lines 342–348).
- **Per-connector environment**: read `connectors/deploy.json`; if the
  connector's package name is in the `public` array, run `pnpm plot deploy -e
  public`, otherwise `pnpm plot deploy -e review`.
- CI's existing `PLOT_DEPLOY_TOKEN` secret must resolve to Plot's publisher,
  which carries the new `can_publish_public` flag (§3).

The change-detection step (`check-changes`) keeps its existing behavior; it just
operates over the combined connector set. The private connectors must be subject
to the same "affected"/changed detection used for public ones.

### 3. Prod authorization — `publisher.can_publish_public`

**Schema** (`libs/db/schema/50-tables/20-publisher.sql`): add

```sql
"can_publish_public" boolean NOT NULL DEFAULT false
```

Expand migration (additive, backward-compatible) via `pnpm gen-migration`. A data
migration in the same file sets `can_publish_public = true` for Plot's own
publisher row. Regenerate and commit `libs/db/src/types.ts`.

**API** (`workers/api/src/sdk/twist.ts`, POST `/twist/:id`):

- **Delete** the dev-only public block at lines 396–419 (the
  `ENV === "development"` + `@plot.day` shortcut).
- After `resolvedPublisherId` is resolved (the existing user-token and
  publisher-token branches, lines 438–483), when `environment === 'public'`, load
  the publisher and return `403` unless `can_publish_public` is `true`. This is
  one uniform rule for every environment (prod and local dev).

Local dev sets the flag on the seeded Plot publisher once (seed/fixture update),
so local `plot deploy -e public` keeps working without the old shortcut.

**CLI** (`public/twister/cli/index.ts` lines 105–106, 130–131; help text only):
add `public` to the `-e/--environment` help string. The server-side Zod enum
already accepts `"public"` (`sdk/twist.ts:84-87`); the CLI passes `-e` through
verbatim, so no other CLI change is required. (This is a Twister/`public/`
submodule change → needs its own PR + changeset.)

### 4. LinkedIn rollout

- Add `@plotday/connector-linkedin` to `connectors/deploy.json`.
- The deploy workflow then deploys it `-e public`, which also refreshes the stale
  `premium` (→ `true`, from `PREMIUM_TWIST_PACKAGE_IDS`) and `version`.
- **Prerequisite (not code, must verify before flipping public):** Unipile prod
  credentials must exist in the prod API worker environment. LinkedIn is
  Unipile-backed (`SCOPES = []`, depends on `@plotday/unipile`); without prod
  Unipile creds the connector deploys but cannot connect.

## Components & Boundaries

| Unit | Responsibility | Depends on |
| --- | --- | --- |
| `connectors/deploy.json` | Declares the public connector set | — (data file) |
| `deploy-twists.yml` discovery + locate + per-connector env | Finds all connectors (both roots); picks deploy env from manifest | `connectors/deploy.json`, `PLOT_DEPLOY_TOKEN` |
| `publisher.can_publish_public` + API check | Authorizes `-e public` server-side | publisher resolution (existing) |
| CLI `-e` help text | Surfaces `public` as a valid target | — |

## Data Flow (public deploy in prod)

```
connectors/deploy.json    CI (deploy-twists.yml)        API worker (prod)
------------------------   ----------------------        -----------------
 "public": [..., linkedin]  discover connectors/* +
                            public/connectors/*
                            for linkedin: in manifest?
                              -> plot deploy -e public  POST /v1/twist/:id
                              (PLOT_DEPLOY_TOKEN)        resolve publisher
                                                        env === 'public' &&
                                                        publisher.can_publish_public?
                                                          -> upsert public twist row
                                                          else 403
```

No DB writes for "promotion" beyond the deploy's own twist-row upsert and the
normal token auth.

## Testing

- **API authorization (core security change):** unit tests that a `-e public`
  deploy is allowed when the resolving publisher has `can_publish_public = true`
  and rejected (`403`) when it does not. Cover both the user-token and
  publisher-token resolution branches.
- **Manifest validation:** a lint/CI step asserting every package name in
  `connectors/deploy.json` resolves to a real connector directory (under
  `connectors/*` or `public/connectors/*`) with a `plotTwistId`. Catches typos
  that would otherwise silently leave a connector in `review`.
- **Migration:** `pnpm diff-schema-migrations` clean; `pnpm --filter @plotday/db
  run lint` (types in sync) green.

## Migration Safety

`can_publish_public` is a nullable-defaulted boolean (`NOT NULL DEFAULT false`) —
a safe additive expand migration; old workers ignore the column. The data
migration setting Plot's publisher flag is idempotent. No contract migration.

## Open Questions / Follow-ups

- **Demotion / removal from `public`.** Removing a connector from the manifest
  makes its next deploy land in `review` but does not remove the existing
  `public` row. If active demotion is needed, that's a separate manual step
  (archive the public row) — out of scope here. Flag if you want CI to reconcile
  removals.
- **Stale review rows.** Connectors that are now public still have old `review`
  rows (with `auto_approve = t`) in prod. They become inert under this model.
  Optional cleanup, not required.

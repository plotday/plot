# Closer-to-zero-downtime deploy — design

Date: 2026-06-02
Branch: `zero-downtime-deploy` (based on `500cc3555`)

## Problem

Two ordering gaps in the production deploy let clients run against an
incompatible counterpart for a window:

1. **Migrations apply before workers deploy.** Inside `deploy-workers.yml`
   the chain is `migrate → deploy`, so between "migrations applied" and "new
   workers live" the **old** worker code runs against the **new** schema.
2. **The web app deploys in parallel with the workers.** In the
   `deploy-production.yml` orchestrator (added in `500cc3555`), `app` and
   `workers` both `needs: gate` only, so the Flutter web app (atomic
   Cloudflare Pages cutover) can go live **before** the API it depends on.
   We design the API to be backward-compatible with old *clients*, but not
   the app to be forward-compatible with an older *API*.

### What `500cc3555` already did

`deploy-production.yml` is now a manual one-click `workflow_dispatch`: a
`gate` job bound to the `production` environment, then it calls the reusable
`deploy-workers` / `deploy-app` / `deploy-site` / `deploy-twists` workflows,
then tags the shipped commit `deploy/<timestamp>`. A deploy is therefore a
**deliberate action that batches every PR merged since the last deploy tag** —
not one run per push. It left both issues above open.

## Core principle

The fix is the classic **expand/contract (parallel-change)** pattern plus a
**layered deploy order** (DB ≤ workers ≤ app), where each layer stays
backward-compatible with the previous version of the layer below during the
rollout window. The migrate-first order is *correct* and cannot simply be
flipped (new code against old schema would break instead); the real fix is to
guarantee migrations are backward-compatible with the currently-running
workers, and to order the app after the workers.

Two kinds of destructive "contract" exist on different clocks:

- **Schema↔worker contract** — drop a column/table no worker references
  anymore. Safe once the *old workers* are gone (seconds–minutes). This is
  what Phase 2 automates.
- **API↔client contract** — remove an API field/endpoint clients call. Safe
  only once old *clients* are gone — weeks–months, and mobile (App Store +
  Shorebird) can't be force-updated. This is always a separate, much-later,
  deliberately-tracked deploy and is **out of scope** here.

## Phase 1 — close both dangers (small, low-risk)

### 1a. App deploys after workers (issue #2)

In `deploy-production.yml`, change the `app` job from `needs: gate` to
`needs: [gate, workers]` with the same guard the existing `twists` job uses:

```yaml
needs: [gate, workers]
if: >-
  ${{ always()
    && needs.gate.result == 'success'
    && inputs.app
    && needs.workers.result != 'failure'
    && needs.workers.result != 'cancelled' }}
```

`always()` keeps the app deploying when the workers checkbox was unticked
(workers `skipped`); it only blocks if workers `failed`/`cancelled`. The web
app can no longer go live before the API (workers includes migrations).

### 1b. Destructive-change gate (issue #1, enforcement)

> **Superseded (2026-06-04):** the gate now runs **Squawk** (`squawk-cli@1.6.1`),
> not Atlas's `migrate lint`. Recent Atlas versions gate `migrate lint` behind
> `atlas login` (a paid Cloud seat) that can't run in CI under our single-seat
> license. The enforcement intent below is unchanged — only the engine and the
> escape-hatch directive (`squawk-ignore` instead of `-- atlas:nolint`) differ.
> See `libs/db/AGENTS.md` "Production Migration Safety" and `libs/db/.squawk.toml`
> for the current mechanics.

Add a `migration-safety` job to `lint.yml` (runs on PRs to `main`) that runs
**Atlas's own `migrate lint`** against migrations added relative to the base
branch. Verified empirically against atlas v1.1.3:

- A destructive change (e.g. `DROP COLUMN`) → analyzer **DS103** → **exit 1**.
  No custom `lint {}` block needed; Atlas errors on destructive changes by
  default.
- A migration that begins with `-- atlas:nolint destructive` → "no diagnostics
  found" → **exit 0**. This is the **sanctioned-contract escape hatch**: a
  developer consciously acknowledges the destructive change (having ensured
  workers no longer use the column), instead of shipping it by accident.

This makes the migrate-first window safe *by construction*: you cannot merge a
migration that breaks the live workers without an explicit acknowledgement.

Mechanics: `atlas migrate lint --env local --git-dir ../.. --git-base
origin/<base>` run from `libs/db`. Skipped when the PR changes no
`libs/db/migrations/*.sql`.

### 1c. Docs

Update `libs/db/AGENTS.md` "Production Migration Safety" to document the gate
and the `-- atlas:nolint destructive` acknowledgement.

## Phase 2 — automate the contract (ergonomic upgrade)

Goal: keep expand + contract in **one PR** without "remember to drop it later,"
while preserving rollback safety. Chosen mechanism: **separate
`migrations-contract/` directory drained at the start of the next deploy**
(the "A-full" model).

- **Why a separate dir.** Atlas applies all pending migrations in a directory
  as one ordered prefix tracked in one revisions table — it can't "apply these
  now, that one later." A separate dir with independent revision tracking lets
  expands and contracts have independent timelines, so a lingering/aborted
  contract never blocks a future expand (the failure mode the single-dir
  "count split" reintroduces, precisely on the recovery path).
- **Drain at next deploy.** A deploy is deliberate and batched, so the
  **inter-deploy gap is the soak**: `deploy-workers.yml` drains
  `migrations-contract/` at the *start* of a deploy (before that deploy's
  expands), applying contracts whose workers went live in a *previous* deploy.
  At drain time the live workers are the previous deploy's (they already
  stopped using the dropped column), so the drop is safe; rollback runway is
  preserved because the contract from *this* deploy's PRs stays pending until
  the *next* deploy. The migration filename's `YYYYMMDDHHMMSS_` prefix gives a
  free minimum-age guard so a contract can't drain before it has soaked ≥ N
  hours.
- **Gate change.** Destructive changes are allowed only in
  `migrations-contract/` (the directory becomes the marker); `migrations/`
  must stay non-destructive. The Phase 1 `-- atlas:nolint` escape hatch in
  `migrations/` is tightened/removed.
- **Tooling.** `gen-migration` / `apply-migrations` / `diff-schema-migrations`
  become two-dir aware (replay both dirs, then diff against `schema/`), so the
  schema-is-source-of-truth invariant still holds. This is the bulk of Phase 2.

Batching is handled cleanly throughout: `atlas migrate apply` applies all
pending expands in order; the contract drainer applies all pending contracts in
order; the `deploy-production` concurrency group (`cancel-in-progress: false`)
serializes the rare double-trigger.

## Out of scope

- Folding `deploy-site` / `deploy-twists` ordering changes (site is marketing;
  twists already `needs: workers`).
- API↔client contracts (governed by client lifetime; separate later deploys).
- Reworking change-detection to diff against the `deploy/*` tag instead of
  `event.before` (useful follow-up, not required here).

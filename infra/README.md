# Infrastructure as Code

Terraform modules for cloud resources that are **not** managed by `wrangler`
(Workers) or Atlas (DB schema). The IaC boundary:

| Layer                                                  | Tool          | Location                  |
| ------------------------------------------------------ | ------------- | ------------------------- |
| Workers code + bindings                                | wrangler      | `workers/*/wrangler.jsonc` |
| DB **schema** (tables, functions, views, triggers)     | Atlas         | `libs/db/`                |
| **Cloud resources** (Cloud SQL instance, Hyperdrive, DNS) | **Terraform** | `infra/`                  |

Terraform owns the *instance*; Atlas owns what's *inside* it. No overlap.

## Modules

- [`cloud-sql/`](./cloud-sql) — the production Cloud SQL instance `plot-prod`,
  its `plot` database, and the `api`/`migrator`/`readonly` users (project
  `plot-core`, region `northamerica-northeast2`).
- [`hyperdrive/`](./hyperdrive) — the shared Cloudflare Hyperdrive config that
  fronts `plot-prod` for the api + classify workers (records `origin_connection_limit`).
- [`cloudflare-dns/`](./cloudflare-dns) — the `plot.day` zone DNS records.
- [`posthog/`](./posthog) — PostHog **capacity-pressure alerting**: a trends
  insight on the `bg.deferred` counter + a threshold alert that emails when the
  background DB lane sheds in a *sustained* way (the push signal for "rebalance
  the 50/30 split or scale Cloud SQL" — see PR #400). Not yet wired into CI; see
  "Activating the posthog alerts" below.

The first three were imported faithfully — `terraform plan` reports **no changes**
for each. The `posthog/` module *creates* new resources (it's not an import).

## Prerequisites

- **Terraform ≥ 1.11** (for the S3 backend's `use_lockfile` state locking and the
  `endpoints` block). The currently-pinned version is in `.tool-versions`:
  ```bash
  asdf plugin add terraform
  asdf install            # installs the pinned version
  terraform version       # must be >= 1.11
  ```
  (or `brew install terraform` for the latest).
- **1Password CLI** signed in to the `plotco` account (`op signin`). The R2
  state-backend credentials live in `op://Production/R2 Terraform State`.
- **gcloud** authenticated as a user with `roles/iam.serviceAccountTokenCreator`
  on the readonly SA (see below) — for the `cloud-sql` module.
- **Cloudflare API token**, read-scoped (Hyperdrive Read + DNS Read + Zone Read),
  at `op://Production/Cloudflare Terraform` — for the `hyperdrive` and
  `cloudflare-dns` modules.
- **PostHog personal API key**, read-scoped, at `op://Production/PostHog Terraform`
  — for the `posthog` module (an `apply` needs a write-scoped key; see "Activating
  the posthog alerts"). These items don't exist yet — provision before first use.

## State

State lives in **Cloudflare R2** (S3-compatible backend), bucket `plot-tf-state`,
one key per module (`cloud-sql/plot-prod.tfstate`, `hyperdrive/plot.tfstate`,
`cloudflare-dns/plot-day.tfstate`, `posthog/plot.tfstate`). Never committed.
Locking via S3 object lockfile (`use_lockfile`). Enable object versioning on the
bucket for recovery.

## Running

Always go through the repo wrapper, which resolves the R2 credentials from
1Password and defaults GCP access to the **readonly** service account:

```bash
pnpm tf cloud-sql init        # one-time per checkout, per module
pnpm tf cloud-sql plan        # must print: No changes.
pnpm tf hyperdrive plan
pnpm tf cloudflare-dns plan
pnpm tf posthog plan          # once the PostHog key item exists
```

Equivalently: `bash scripts/terraform <module> <args...>` from the repo root. The
wrapper resolves R2 state creds plus the right cloud credential per module (the
readonly GCP SA for `cloud-sql`, a read-scoped `CLOUDFLARE_API_TOKEN` for the
Cloudflare modules, a read-scoped `POSTHOG_API_KEY` for `posthog`).

### Read-only by default

The wrapper exports `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT=claude-readonly@plot-core…`,
so `plan`/`import` work but any `apply` of a real change **fails** on missing
write permission — by design. **Capacity/durability changes** (e.g. ZONAL→REGIONAL
HA, an explicit `max_connections`) are deliberate, separately-reviewed diffs run
with a writable identity (override `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT`, or set an
edit-scoped `CLOUDFLARE_API_TOKEN`, before the apply) — never smuggled into a
refresh. Note: the Hyperdrive `origin.password` is a write-only secret the API
never returns, so it's set to a placeholder and ignored; prefer
`scripts/deploy-hyperdrive` (a safe partial update) for pool-size changes.

## In CI

Two workflows drive the same `scripts/terraform` wrapper (creds resolved live
from 1Password via `OP_SERVICE_ACCOUNT_TOKEN` — no GitHub-secret snapshots):

- **`infra-plan.yml`** — read-only `terraform plan` on PRs that touch `infra/**`
  (preview) and on a daily schedule (drift check; fails if production has drifted
  from code). Uses a read-only GCP key + the read-scoped CF token.
- **`deploy-infra.yml`** — `terraform apply` of all three modules, run **first**
  in `deploy-production.yml` (after the `production` approval gate, before
  migrations/workers) so infra is in place before code ships. Runs on **every**
  production deploy; zero-diff is a no-op. It plans to a saved file then applies
  exactly that. If it fails, all downstream deploy jobs are blocked.

Because apply runs every deploy, a change made by hand in the Cloudflare/GCP
console will be **reverted** on the next deploy unless it's also in code — that's
the IaC contract; use a PR (the `infra-plan` preview shows the diff).

> **`posthog` is intentionally NOT in either workflow's module list yet.** The
> wrapper hard-fails if the PostHog key item is absent, so adding `posthog` to the
> loops *before* the 1Password items exist would fail the `infra-plan` check on
> every infra PR and break every production deploy at the infra stage. The module
> files + wrapper case ship inert (CI never invokes `posthog`); the loops are
> flipped on as the last step of "Activating the posthog alerts" once the keys
> are provisioned.

### Credentials to provision (CI write path)

`apply` needs writable identities; provision these in 1Password (the op service
account must be able to read them). These are also what the capacity work needs:

- `op://Production/GCP Terraform/credential` — **writable** GCP SA key (JSON),
  e.g. a `terraform-deploy@plot-core` SA with `roles/cloudsql.admin`.
- `op://Production/GCP Terraform Readonly/credential` — read-only GCP SA key
  (e.g. a key for `claude-readonly@plot-core`), used by the plan/drift workflow.
- `op://Production/Cloudflare Terraform Edit/credential` — edit-scoped CF token
  (Hyperdrive Edit + DNS Edit + Zone Read).
- `op://Production/PostHog Terraform/credential` — **read-scoped** PostHog personal
  API key (scopes `insight:read`, `alert:read`), used by the plan/drift workflow.
- `op://Production/PostHog Terraform/edit credential` — **write-scoped** PostHog
  personal API key (scopes `insight:read`, `insight:write`, `alert:read`,
  `alert:write`), scoped to the Plot org/project, used by `apply`. Same item as the
  read key above, in the `edit credential` field.

(The read-scoped CF token at `op://Production/Cloudflare Terraform`, the R2 state
token, and `OP_SERVICE_ACCOUNT_TOKEN` already exist; the `PostHog Terraform` item
and its two fields do not yet — see below.) Prefer Workload Identity Federation over long-lived GCP keys if
you want to avoid storing keys at all.

## Activating the posthog alerts

The `posthog/` module is committed but inert until its credentials exist and it's
wired into CI. One-time, by a human with PostHog org access:

1. **Create two PostHog personal API keys** (PostHog → Settings → Personal API
   keys), both scoped to the Plot organization/project, both stored in the one
   `op://Production/PostHog Terraform` item:
   - read key → `credential` field (`insight:read`, `alert:read`).
   - write key → `edit credential` field
     (`insight:read`+`write`, `alert:read`+`write`).
   The op service account must be able to read the item.
2. **Apply once, manually**, with the write key, to create the insight + alert:
   ```bash
   TF_POSTHOG_OP_FIELD="edit credential" \
     pnpm tf posthog init
   TF_POSTHOG_OP_FIELD="edit credential" \
     pnpm tf posthog apply
   ```
   (Plain `pnpm tf posthog plan` uses the read key and previews without changes.)
3. **Wire it into CI** so drift is caught and future changes auto-apply: add
   `posthog` to the module loops in `.github/workflows/infra-plan.yml` (both the
   `plan` and summary `for m in …` loops) and to the default `modules` input in
   `.github/workflows/deploy-infra.yml`, and add
   `TF_POSTHOG_OP_FIELD: "edit credential"` to the
   `deploy-infra.yml` apply step's `env:` (mirroring `TF_CF_OP_ITEM`). Do this
   **only after** step 1 — the wrapper hard-fails without the key.
4. **Tune the threshold.** `threshold_upper` in `infra/posthog/alerts.tf` is a
   conservative first cut; once PR #400's counters have a few days of baseline,
   set it just above a normal busy hour (a reviewed, plan-previewed edit).
   Verify recipients: the alert emails PostHog user id `157794` (kris@plot.day).

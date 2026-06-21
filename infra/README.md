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

All imported faithfully — `terraform plan` reports **no changes** for each.

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

## State

State lives in **Cloudflare R2** (S3-compatible backend), bucket `plot-tf-state`,
one key per module (`cloud-sql/plot-prod.tfstate`, `hyperdrive/plot.tfstate`,
`cloudflare-dns/plot-day.tfstate`). Never committed. Locking via S3 object
lockfile (`use_lockfile`). Enable object versioning on the bucket for recovery.

## Running

Always go through the repo wrapper, which resolves the R2 credentials from
1Password and defaults GCP access to the **readonly** service account:

```bash
pnpm tf cloud-sql init        # one-time per checkout, per module
pnpm tf cloud-sql plan        # must print: No changes.
pnpm tf hyperdrive plan
pnpm tf cloudflare-dns plan
```

Equivalently: `bash scripts/terraform <module> <args...>` from the repo root. The
wrapper resolves R2 state creds plus the right cloud credential per module (the
readonly GCP SA for `cloud-sql`, a read-scoped `CLOUDFLARE_API_TOKEN` for the
Cloudflare modules).

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

### Credentials to provision (CI write path)

`apply` needs writable identities; provision these in 1Password (the op service
account must be able to read them). These are also what the capacity work needs:

- `op://Production/GCP Terraform/credential` — **writable** GCP SA key (JSON),
  e.g. a `terraform-deploy@plot-core` SA with `roles/cloudsql.admin`.
- `op://Production/GCP Terraform Readonly/credential` — read-only GCP SA key
  (e.g. a key for `claude-readonly@plot-core`), used by the plan/drift workflow.
- `op://Production/Cloudflare Terraform Edit/credential` — edit-scoped CF token
  (Hyperdrive Edit + DNS Edit + Zone Read).

(The read-scoped CF token at `op://Production/Cloudflare Terraform`, the R2 state
token, and `OP_SERVICE_ACCOUNT_TOKEN` already exist.) Prefer Workload Identity
Federation over long-lived GCP keys if you want to avoid storing keys at all.

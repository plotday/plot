# Windows Store publishing (msstore)

The `release-windows` job in `.github/workflows/release.yml` uploads the built
MSIX (`Plot-<version>.msix`) to the Microsoft Store using Microsoft's
[`msstore` CLI](https://learn.microsoft.com/windows/apps/publish/msstore-dev-cli/overview),
the same way iOS/macOS/Android auto-upload their builds.

- **Build upload only** — listing text and screenshots are not changed by the
  pipeline.
- **Draft by default** — the upload creates/updates a Partner Center submission
  but does **not** send it to certification. Tick the **"Submit uploaded store
  builds for review/certification"** checkbox when running the Release workflow
  to commit it (`--noCommit` is dropped).
- **Credential-guarded** — if the secrets below are absent, the Store steps log
  a warning and skip, so a Windows release is never blocked.

Product: **Plot**, Partner Center product ID `9PKTCSN8SNZF`.

## One-time setup (required before the first upload)

The app is already live in the Store. To enable API uploads:

1. Register an application in **Microsoft Entra ID**
   (Entra admin center → App registrations → New registration).
2. Under **Certificates & secrets**, create a **client secret**; copy its value
   immediately (it is shown only once).
3. In **Partner Center → Account settings → User management → Microsoft Entra
   applications**, add that app and assign it the **Manager** role.
4. Collect: **Tenant ID**, **Client ID** (the app's Application ID), the
   **Client secret** value, and your **Seller ID** (Partner Center →
   Account settings → Identifiers / "Seller ID").

## Secrets (managed in 1Password)

Like all CI credentials, these live in 1Password and sync to GitHub Actions
secrets via `scripts/sync-github-secrets` (run by the `refresh-secrets` job at
the start of every deploy). Do **not** add them by hand in the GitHub UI.

Store them in the **Production** vault, item **"Windows Store"**, with these
fields:

| 1Password field (item "Windows Store") | → GitHub secret | Source |
| --- | --- | --- |
| `Tenant ID` | `AZURE_AD_TENANT_ID` | Entra Directory (tenant) ID |
| `App client ID` | `AZURE_AD_APPLICATION_CLIENT_ID` | App registration Application (client) ID |
| `password` | `AZURE_AD_APPLICATION_SECRET` | App registration client secret **Value** (not the Secret ID) |
| `Seller ID` | `SELLER_ID` | Partner Center Seller ID |

Once the item exists, the next deploy's `refresh-secrets` job pushes all four
to GitHub, and the next Windows release uploads to the Store automatically.

## Caveats

- **Free products only (currently).** Microsoft's GitHub Actions path supports
  app updates for **free** products only; paid-product support is "a future
  release." Plot is free-to-download, so this applies — but confirm the product
  is not classed as paid before the first run.
- **Pending-draft collisions.** `msstore publish` creates a *new* submission. If
  a previous draft is still open in Partner Center (e.g. a prior default/draft
  run not yet committed or deleted), a later run can error until that draft is
  resolved — commit or delete it in Partner Center (or `msstore submission
  delete <productId>`).
- The `msstore` CLI is in preview; the action is pinned to `@v1.2`.

## Listing metadata

On every `release-windows` run with Store credentials configured, the workflow
pushes the listing **text** to the pending submission, then commits it together
with the package when `submit_for_review` is checked.

**Source files** (`apps/plot/windows/store/en-US/`, one field per file):

| File | Store field |
| --- | --- |
| `description.txt` | Description (≤ 10,000 chars) |
| `short_description.txt` | Short description (one line) |
| `features.txt` | Product features (one per line, ≤ 20, ≤ 200 chars) |
| `search_terms.txt` | Search terms (one per line, ≤ 7, ≤ 30 chars) |

**How it works:** the workflow runs `msstore submission get`, patches only those
four fields with `jq`, and calls `msstore submission updateMetadata`. For
packaged (MSIX) apps `updateMetadata` is a *full replace*, so the workflow
fetches the whole submission and overwrites only the text — **screenshots and
every other field are preserved**.

**Still manual in Partner Center:**

- **Screenshots / images** — the `updateMetadata` path cannot upload image bytes
  (that lives only in the `msstore publish <project>` project-init flow, which
  this pipeline does not use). Upload screenshots once in Partner Center; the
  workflow leaves them untouched on every run.
- **Release notes** and the **product / reserved name** — out of scope.

**Precondition:** app updates via the CLI are supported for **free** products
only; the CLI deletes the submission and errors on a paid product. Plot's listing
is free.

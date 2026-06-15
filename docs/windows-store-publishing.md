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

## GitHub repository secrets

Add these under **Settings → Secrets and variables → Actions** (names match
Microsoft's documentation):

| Secret | Value |
| --- | --- |
| `AZURE_AD_TENANT_ID` | Entra tenant ID |
| `AZURE_AD_APPLICATION_CLIENT_ID` | App registration Application (client) ID |
| `AZURE_AD_APPLICATION_SECRET` | App registration client secret value |
| `SELLER_ID` | Partner Center Seller ID |

Once all four exist, the next Windows release uploads to the Store automatically.

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

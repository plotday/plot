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
   applications**, add that app and assign it the **Manager** role — **on the
   Microsoft Store developer account that owns Plot, and only that account**
   (see [Account topology](#account-topology--the-two-account-gotcha) below;
   getting this wrong is the #1 cause of upload failures).
4. Collect: **Tenant ID**, **Client ID** (the app's Application ID), the
   **Client secret** value, and the **Store account's Seller ID** (Partner
   Center → Account settings → Identifiers).

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
| `Seller ID` | `SELLER_ID` | The **Store developer account's** Seller ID (not the Marketplace account's `93590530`) |

Once the item exists, the next deploy's `refresh-secrets` job pushes all four
to GitHub, and the next Windows release uploads to the Store automatically.

## Account topology — the two-account gotcha

> If `msstore publish` fails with **"Could not retrieve your application"**, read
> this first — it has been the cause every time.

Plot is published under **two different Partner Center accounts that share the
same `kris@plot.day` email** but are different identity *types*:

| | Commercial Marketplace account | **Microsoft Store developer account** |
| --- | --- | --- |
| Account-switcher name | `Plot-plot` | **`Plot Technologies Inc.`** |
| Identity type | work / **Entra** user | personal / **MSA** |
| Identifier | Seller ID `93590530`, Partner ID `7078039` | Windows publisher ID `CN=3C1B8AFA-75E1-42FE-9717-EB9D1B1820CB` |
| Owns Store apps? | **No** | **Yes — Plot (`9PKTCSN8SNZF`) lives here** |

The msstore submission API resolves the developer account from the **Entra app's
association**, *not* from the Seller ID. So the Entra app — and therefore the
secrets — must be associated with the **Store developer account**, and with
**only** that one.

### Symptoms of getting it wrong

`msstore publish` → `💥 Could not retrieve your application…` (exit 127). Under
the hood auth *succeeds* (token `200`), but `GET /my/applications` returns an
**empty list** and `GET /my/applications/9PKTCSN8SNZF` returns **`403`**. Two
distinct mistakes both produce this:

1. The Entra app is associated with the **Marketplace** account (owns no Store apps).
2. The **same** Entra app is associated with **both** accounts — ambiguous; the
   API still resolves to the Marketplace account.

### The working configuration (set up 2026-06-19)

1. **Associate the Entra tenant with the Store account.** Store account →
   Account settings → **Tenants → Associate Microsoft Entra tenant**; sign in as
   a **Global Admin** of the `plot.day` tenant
   (`e6b8e1e6-b0b5-429d-b5a1-3dbed8e1401e`). This makes the Store account
   manageable via the Entra identity and surfaces it in the Partner Center
   **account switcher** (top-right) under the "Plot Technologies Inc." directory.
   - ⚠️ Because the same email is *both* an MSA and an Entra user, the
     "Sign in with Microsoft Entra ID" button on the Store account's User
     management page can bounce you into the Marketplace account. Use the
     **account switcher** and pick **"Plot Technologies Inc."** explicitly.
2. **Associate the Entra app with the Store account** (User management →
   Microsoft Entra applications → Add → the `Windows Store` app → **Manager**).
3. **Remove that app's association from the Marketplace account** so it maps to
   **exactly one** account (its User management → Microsoft Entra applications →
   select `Windows Store` → **Delete**). This is the step that clears the `403`.
   The Marketplace account has no Store apps, so it doesn't need the app.
4. Set **`Seller ID`** in 1Password to the **Store account's** seller ID (not the
   Marketplace `93590530`), then re-run `scripts/sync-github-secrets`.

## Verifying the credentials (read-only probe)

To check whether the configured 1Password creds can actually retrieve Plot —
without waiting for a release and without printing any secret — authenticate and
list the apps the principal can see:

```bash
TENANT=$(op read 'op://Production/Windows Store/Tenant ID')
CLIENT=$(op read 'op://Production/Windows Store/App client ID')
SECRET=$(op read 'op://Production/Windows Store/password')
TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  -d grant_type=client_credentials --data-urlencode "client_id=$CLIENT" \
  --data-urlencode "client_secret=$SECRET" \
  --data-urlencode "scope=https://manage.devcenter.microsoft.com/.default" \
  | jq -r .access_token)
# Should list Plot:
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://manage.devcenter.microsoft.com/v1.0/my/applications" \
  | jq -r '.value[]? | "\(.id)  \(.primaryName)"'
# Should print 200:
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" \
  "https://manage.devcenter.microsoft.com/v1.0/my/applications/9PKTCSN8SNZF"
```

`9PKTCSN8SNZF` in the list **and** `200` from the second call = the app is
correctly associated with the Store account. Empty list / `403` = the topology
problem above. (The probe does **not** send the Seller ID, so it isolates the
app-association: a passing probe means publishing will work even before the
Seller ID is corrected.)

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

# Windows Store auto-publish via msstore CLI — design

**Date:** 2026-06-15
**Status:** Design (awaiting review)

## Problem

The `release-windows` job in `.github/workflows/release.yml` builds a signed,
Store-identity MSIX (`Plot-<version>.msix`), ships it to R2 / `download.plot.day`
and a GitHub Release, then **stops**. Pushing that MSIX to the Microsoft Store is
**manual** — the job summary just links to Partner Center product
`9PKTCSN8SNZF`. Every other platform in the same workflow auto-uploads its build:

- **iOS / macOS** — `xcrun altool --upload-app` to App Store Connect.
- **Android** — `fastlane beta` → `upload_to_play_store` (internal track,
  `skip_upload_metadata: true`, `release_status: 'draft'`).

None of those steps touch store **listing** metadata; they upload the **build**
only, and Android lands as a **draft**. We want Windows to reach parity: the
release pipeline uploads the freshly built MSIX to the Store automatically.

## Goal

Add a Microsoft Store **build upload** to `release-windows` using Microsoft's
`msstore` CLI, gated so it:

- uploads the MSIX the job already produced (no rebuild, no metadata changes),
- defaults to leaving the submission as a **draft** in Partner Center, with an
  opt-in checkbox to submit it for certification,
- **no-ops cleanly until credentials exist**, so the next Windows release does
  not break before the one-time Partner Center setup is done.

## Decisions (from brainstorming)

1. **Tool:** Microsoft Store Developer CLI (`msstore`). Fastlane has no
   maintained Microsoft Store path; `msstore` is Microsoft's official CLI, has
   first-class CI/CD + a GitHub Action, and runs the upload from the existing
   `windows-2022` runner.
2. **Scope: build upload only.** No listing metadata (`updateMetadata`). Matches
   every other platform in this workflow. Metadata automation can be a separate
   follow-up.
3. **Disposition: draft by default, opt-in submit.** A new boolean
   `workflow_dispatch` input controls whether the uploaded submission is
   committed to certification. Default `false` → `msstore publish ... --noCommit`
   (draft); `true` → omit `--noCommit` (commits → certification).
4. **Trigger: always, on every Windows release.** No separate "push to Store"
   toggle — the upload runs whenever `release-windows` runs. Robustness comes
   from the credential guard (decision 6), not from a manual gate.
5. **Input name is platform-neutral (`submit_for_review`).** The user asked for a
   "submit for certification" checkbox and will have another agent wire the same
   flag into iOS/Android review submission later, so the name is generic. Only
   the Windows job consumes it in this change.
6. **Credential guard.** Secrets do not exist yet. A check step sets a step
   output from whether the client-ID secret is non-empty; the install + publish
   steps are gated on it. Missing secrets → a `::warning::` and skip (exit 0), so
   the release is never blocked. Adding the four secrets later activates the
   feature with no further code change.
7. **Placement: after the GitHub Release is created.** The primary distribution
   channels (R2 / `download.plot.day` + GitHub Release) complete first, so a
   Store API hiccup can't prevent the artifacts users actually download.
8. **Secret names follow Microsoft's documented names** so they line up with the
   Partner Center setup the user will follow:
   `AZURE_AD_TENANT_ID`, `AZURE_AD_APPLICATION_CLIENT_ID`,
   `AZURE_AD_APPLICATION_SECRET`, `SELLER_ID`.

## Why this is feasible

- The MSIX already carries the **Store-reserved identity** (`pubspec.yaml`:
  `identity_name: PlotTechnologiesInc.Plot-TractiononPriorities`,
  `publisher: CN=3C1B8AFA-...`), which is what Partner Center requires. The Store
  re-signs on ingestion, so the existing self-signed packaging cert is fine.
- The app is **already live** in the Store (manual uploads to date), satisfying
  msstore's "app must be published" precondition.
- `msstore` for a prebuilt MSIX is a single command:
  `msstore publish "<file>.msix" -id <productId> [--noCommit]` (per Microsoft's
  GitHub Actions guide).

## Design

### 1. New workflow input

In `release.yml` under `workflow_dispatch.inputs`, alongside the existing
`windows` input:

```yaml
submit_for_review:
  description: 'Submit uploaded store builds for review/certification (off = upload as draft)'
  type: boolean
  default: false
```

Consumed only by `release-windows` in this change.

### 2. Three new steps in `release-windows`

Inserted **after** "Create GitHub Release" and **before** "Tag store submission".

**a. Check Microsoft Store credentials** — gates the rest.

```yaml
- name: Check Microsoft Store credentials
  id: ms-store
  shell: bash
  env:
    AZURE_AD_APPLICATION_CLIENT_ID: ${{ secrets.AZURE_AD_APPLICATION_CLIENT_ID }}
  run: |
    if [ -n "$AZURE_AD_APPLICATION_CLIENT_ID" ]; then
      echo "enabled=true" >> "$GITHUB_OUTPUT"
    else
      echo "enabled=false" >> "$GITHUB_OUTPUT"
      echo "::warning::Microsoft Store credentials not configured — skipping Store publish."
    fi
```

(Secrets cannot be referenced in step `if:` expressions, so the non-empty check
runs inside a step and exposes a plain output the later `if:`s can use.)

**b. Set up msstore CLI** — only when enabled.

```yaml
- name: Set up Microsoft Store Developer CLI
  if: steps.ms-store.outputs.enabled == 'true'
  uses: microsoft/setup-msstore-cli@v1.2
```

(Same action Microsoft's docs use; no separate `setup-dotnet` needed on
`windows-2022`.)

**c. Publish MSIX to Microsoft Store** — authenticate, then upload.

```yaml
- name: Publish MSIX to Microsoft Store
  if: steps.ms-store.outputs.enabled == 'true'
  shell: bash
  env:
    AZURE_AD_TENANT_ID: ${{ secrets.AZURE_AD_TENANT_ID }}
    SELLER_ID: ${{ secrets.SELLER_ID }}
    AZURE_AD_APPLICATION_CLIENT_ID: ${{ secrets.AZURE_AD_APPLICATION_CLIENT_ID }}
    AZURE_AD_APPLICATION_SECRET: ${{ secrets.AZURE_AD_APPLICATION_SECRET }}
    SUBMIT_FOR_REVIEW: ${{ inputs.submit_for_review }}
  run: |
    cd apps/plot/build/windows/x64/runner/Release
    MSIX_FILE="Plot-${{ needs.prepare-release.outputs.release_version }}.msix"

    msstore reconfigure \
      --tenantId "$AZURE_AD_TENANT_ID" \
      --sellerId "$SELLER_ID" \
      --clientId "$AZURE_AD_APPLICATION_CLIENT_ID" \
      --clientSecret "$AZURE_AD_APPLICATION_SECRET"

    NOCOMMIT="--noCommit"
    if [ "$SUBMIT_FOR_REVIEW" = "true" ]; then NOCOMMIT=""; fi

    msstore publish "$MSIX_FILE" -id 9PKTCSN8SNZF $NOCOMMIT
```

Product ID `9PKTCSN8SNZF` is already present in the job (the Partner Center
link); reusing the literal keeps it consistent.

### 3. Build summary

Extend the existing "Build summary" step to report the Store outcome — submitted
for certification, uploaded as draft, or skipped (credentials absent) — derived
from `steps.ms-store.outputs.enabled` and `inputs.submit_for_review`.

### 4. Documentation

A short setup doc (e.g. `docs/windows-store-publishing.md`) covering the one-time
Partner Center prerequisites and the four GitHub secrets, plus the draft-vs-submit
behavior. Linked from the release runbook if one exists.

## One-time prerequisites (manual, cannot be automated)

Per Microsoft's GitHub Actions guide:

1. Register an application in Microsoft Entra ID.
2. In Partner Center → Account settings → User management → Microsoft Entra
   applications, add that app and assign it the **Manager** role.
3. Collect Tenant ID, Client ID, Client secret, Seller ID.
4. Add them as GitHub repo secrets: `AZURE_AD_TENANT_ID`,
   `AZURE_AD_APPLICATION_CLIENT_ID`, `AZURE_AD_APPLICATION_SECRET`, `SELLER_ID`.

The app must already be published and live in the Store (it is).

## Risks & limitations

1. **⚠️ Free products only (today).** Microsoft's docs state app-update via the
   GitHub Action is "currently supported for free products only. Paid products
   will be supported in a future release." Plot is free-to-download, so this
   should apply — **confirm before first run** that the Store product is not
   classed as paid.
2. **Pending-draft collisions.** `msstore publish` creates a *new* submission. If
   a prior draft is still open in Partner Center (e.g. a previous `--noCommit`
   run not yet committed/deleted), a later run can error until that draft is
   resolved. Accepted as a known v1 limitation — no auto-delete of drafts.
   Operator resolves via Partner Center or `msstore submission delete`.
3. **`msstore` is preview.** Stable enough that Microsoft documents it as the CI
   path, but version-pin the action (`@v1.2`) so it can't drift.
4. **Secret hygiene.** Credentials are passed to `msstore reconfigure` as flags
   via env vars; GitHub masks secret values in logs.

## Out of scope

- Listing metadata automation (`submission updateMetadata`).
- Wiring `submit_for_review` into iOS/macOS/Android (handled by a separate agent).
- Flighting / staged package rollout (`--flightId`, `--packageRolloutPercentage`).

## Files touched

- `.github/workflows/release.yml` — new input + 3 steps + summary update.
- `docs/windows-store-publishing.md` — new setup/runbook doc.

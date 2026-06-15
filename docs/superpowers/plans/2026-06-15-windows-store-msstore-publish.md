# Windows Store auto-publish via msstore CLI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Microsoft Store build upload to the `release-windows` job so a Windows release auto-uploads its MSIX to Partner Center, mirroring how iOS/macOS/Android auto-upload their builds.

**Architecture:** Three new steps are appended to the existing `release-windows` job in `.github/workflows/release.yml`, after the GitHub Release is created. They (a) check whether Store credentials exist and skip cleanly if not, (b) install Microsoft's `msstore` CLI, and (c) authenticate and `msstore publish` the already-built `Plot-<version>.msix`. A new `submit_for_review` workflow input toggles draft (`--noCommit`, default) vs. submit-for-certification. No rebuild, no listing-metadata changes.

**Tech Stack:** GitHub Actions (YAML), bash, Microsoft Store Developer CLI (`msstore`), `microsoft/setup-msstore-cli` action. Spec: `docs/superpowers/specs/2026-06-15-windows-store-msstore-publish-design.md`.

---

## Working context (READ FIRST)

- **Workspace:** worktree `.claude/worktrees/windows-store-msstore-publish`, branch `windows-store-msstore-publish`, based on `origin/main`. All paths below are relative to that worktree root. Run all commands from the worktree root.
- **Commits must use `--no-verify`.** This worktree skipped `pnpm install`, so the husky pre-commit hook is missing (`.husky/_/husky.sh: No such file or directory`) and a plain `git commit` fails. The change is YAML + Markdown only, so skipping the hook is safe. CI still runs full checks on the eventual PR.
- **Verification tool:** `actionlint` (installed at `/opt/homebrew/bin/actionlint`). **Baseline:** running `actionlint .github/workflows/release.yml` before any change reports exactly ONE finding — a pre-existing `SC2086:info` in the Android `release-android` job (around line 587, `Install fastlane` / `fastlane beta`). Every task below must keep that the *only* finding. New steps must introduce **zero** new actionlint/shellcheck findings.
- **No local end-to-end test is possible.** Actually running the Store upload requires the Partner Center secrets (which do not exist yet) and a real Windows release. Verification in this plan is therefore: YAML/actionlint validity + structural `grep` assertions + diff review. The true E2E test is the first real Windows release after the secrets are added — out of scope here. Do **not** fabricate a test harness for it.

## File Structure

- **Modify:** `.github/workflows/release.yml`
  - `on.workflow_dispatch.inputs` — add `submit_for_review` boolean input (Task 1).
  - `release-windows` job — insert 3 steps after "Create GitHub Release", before "Tag store submission" (Task 2).
  - `release-windows` → "Build summary" step — add a Microsoft Store status line (Task 3).
- **Create:** `docs/windows-store-publishing.md` — one-time Partner Center setup + secrets + behavior (Task 4).

---

### Task 1: Add the `submit_for_review` workflow input

**Files:**
- Modify: `.github/workflows/release.yml` (the `windows:` input block, ~lines 18-21)

- [ ] **Step 1: Add the input after the `windows` input**

Apply this exact edit. Match (old):

```yaml
      windows:
        description: 'Release Windows'
        type: boolean
        default: true

concurrency:
```

Replace with (new):

```yaml
      windows:
        description: 'Release Windows'
        type: boolean
        default: true
      submit_for_review:
        description: 'Submit uploaded store builds for review/certification (off = upload as draft)'
        type: boolean
        default: false

concurrency:
```

- [ ] **Step 2: Verify the input parses and is present**

Run:
```bash
actionlint .github/workflows/release.yml 2>&1 | grep -vE "SC2086" ; echo "=== actionlint-filtered-done ==="
grep -n "submit_for_review:" .github/workflows/release.yml
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"
```
Expected: nothing prints from actionlint before `=== actionlint-filtered-done ===` (the only finding is the pre-existing `SC2086` in the `release-android` job, which is filtered out by message — robust to the line shifting from ~587 to ~591 after this 4-line insert); `grep` prints one match for `submit_for_review:`; `YAML OK` prints.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit --no-verify -m "ci(release): add submit_for_review input for store builds"
```

---

### Task 2: Add the Microsoft Store publish steps to `release-windows`

**Files:**
- Modify: `.github/workflows/release.yml` (`release-windows` job, between "Create GitHub Release" and "Tag store submission")

- [ ] **Step 1: Insert the three steps**

Apply this exact edit. Match (old) — this is the tail of the "Create GitHub Release" step's `gh release create` command, immediately followed by the "Tag store submission" step. This combination is unique to the `release-windows` job:

```yaml
            "$ZIP_FILE"

      - name: Tag store submission
        shell: bash
        run: |
          git tag "windows/${{ needs.prepare-release.outputs.release_version }}"
          git push origin "windows/${{ needs.prepare-release.outputs.release_version }}"
```

Replace with (new):

```yaml
            "$ZIP_FILE"

      - name: Check Microsoft Store credentials
        id: ms-store
        shell: bash
        env:
          AZURE_AD_APPLICATION_CLIENT_ID: ${{ secrets.AZURE_AD_APPLICATION_CLIENT_ID }}
        run: |
          # Secrets cannot be referenced in step `if:` expressions, so gate the
          # Store steps on a plain output derived from a non-empty client ID.
          # Until the Partner Center secrets are added, this no-ops cleanly so a
          # Windows release is never blocked by missing Store credentials.
          if [ -n "$AZURE_AD_APPLICATION_CLIENT_ID" ]; then
            echo "enabled=true" >> "$GITHUB_OUTPUT"
          else
            echo "enabled=false" >> "$GITHUB_OUTPUT"
            echo "::warning::Microsoft Store credentials not configured — skipping Store publish."
          fi

      - name: Set up Microsoft Store Developer CLI
        if: steps.ms-store.outputs.enabled == 'true'
        uses: microsoft/setup-msstore-cli@v1.2

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

          # Authenticate msstore with the Partner Center Entra app credentials.
          msstore reconfigure \
            --tenantId "$AZURE_AD_TENANT_ID" \
            --sellerId "$SELLER_ID" \
            --clientId "$AZURE_AD_APPLICATION_CLIENT_ID" \
            --clientSecret "$AZURE_AD_APPLICATION_SECRET"

          # Product 9PKTCSN8SNZF = Plot in Partner Center (same ID linked in the
          # build summary below). Default leaves the submission as a draft;
          # submit_for_review=true commits it to certification.
          if [ "$SUBMIT_FOR_REVIEW" = "true" ]; then
            msstore publish "$MSIX_FILE" -id 9PKTCSN8SNZF
          else
            msstore publish "$MSIX_FILE" -id 9PKTCSN8SNZF --noCommit
          fi

      - name: Tag store submission
        shell: bash
        run: |
          git tag "windows/${{ needs.prepare-release.outputs.release_version }}"
          git push origin "windows/${{ needs.prepare-release.outputs.release_version }}"
```

- [ ] **Step 2: Verify structure and no new lint findings**

Run:
```bash
actionlint .github/workflows/release.yml 2>&1 | grep -vE "SC2086" ; echo "=== actionlint-filtered-done ==="
grep -n "Publish MSIX to Microsoft Store\|setup-msstore-cli\|msstore publish\|steps.ms-store.outputs.enabled" .github/workflows/release.yml
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"
```
Expected:
- The actionlint line prints nothing between the command and `=== actionlint-filtered-done ===` (the only pre-existing finding is `SC2086`, which is filtered out; the new `if/else` bash deliberately avoids any unquoted-variable `SC2086`). If anything else prints, fix it before continuing.
- `grep` shows: one `Publish MSIX to Microsoft Store`, one `setup-msstore-cli`, two `msstore publish` lines, and at least two `steps.ms-store.outputs.enabled` (the two `if:` gates).
- `YAML OK` prints.

- [ ] **Step 3: Confirm the steps sit inside `release-windows` (not another job)**

Run:
```bash
awk '/^  release-windows:/{f=1} f&&/Publish MSIX to Microsoft Store/{print "FOUND in release-windows at line " NR; exit}' .github/workflows/release.yml
```
Expected: prints `FOUND in release-windows at line <N>`. If it prints nothing, the insertion landed in the wrong job — revert and re-apply against the unique `"$ZIP_FILE"` + Tag-step anchor.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit --no-verify -m "ci(release): upload Windows MSIX to Microsoft Store via msstore"
```

---

### Task 3: Report Store status in the build summary

**Files:**
- Modify: `.github/workflows/release.yml` (`release-windows` → "Build summary" step)

- [ ] **Step 1: Add a Microsoft Store section to the summary**

Apply this exact edit. Match (old):

```yaml
            echo "### Admin"
            echo "- [Microsoft Partner Center](https://partner.microsoft.com/en-us/dashboard/products/9PKTCSN8SNZF/)"
          } >> "$GITHUB_STEP_SUMMARY"
```

Replace with (new):

```yaml
            echo "### Microsoft Store"
            if [ "${{ steps.ms-store.outputs.enabled }}" != "true" ]; then
              echo "- ⏭️ Skipped (Store credentials not configured)"
            elif [ "${{ inputs.submit_for_review }}" = "true" ]; then
              echo "- ✅ Uploaded and submitted for certification"
            else
              echo "- 📝 Uploaded as draft — submit it in Partner Center"
            fi
            echo ""
            echo "### Admin"
            echo "- [Microsoft Partner Center](https://partner.microsoft.com/en-us/dashboard/products/9PKTCSN8SNZF/)"
          } >> "$GITHUB_STEP_SUMMARY"
```

(`steps.ms-store` is in the same job and its check step always runs, so the output is always set by the time the summary runs.)

- [ ] **Step 2: Verify**

Run:
```bash
actionlint .github/workflows/release.yml 2>&1 | grep -vE "SC2086" ; echo "=== done ==="
grep -n '### Microsoft Store' .github/workflows/release.yml
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"
```
Expected: nothing prints from actionlint before `=== done ===`; one `### Microsoft Store` match; `YAML OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit --no-verify -m "ci(release): report Microsoft Store status in Windows build summary"
```

---

### Task 4: Add the setup/runbook doc

**Files:**
- Create: `docs/windows-store-publishing.md`

- [ ] **Step 1: Write the doc**

Create `docs/windows-store-publishing.md` with exactly this content:

````markdown
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
````

- [ ] **Step 2: Verify the doc exists and renders as valid Markdown**

Run:
```bash
test -f docs/windows-store-publishing.md && echo "doc present"
grep -c "AZURE_AD_TENANT_ID\|9PKTCSN8SNZF\|Manager role\|free" docs/windows-store-publishing.md
```
Expected: `doc present`; the count is `>= 4` (key facts present).

- [ ] **Step 3: Commit**

```bash
git add docs/windows-store-publishing.md
git commit --no-verify -m "docs: Windows Store publishing setup and runbook"
```

---

### Task 5: Final whole-file verification

- [ ] **Step 1: Full actionlint + YAML pass**

Run:
```bash
actionlint .github/workflows/release.yml ; echo "actionlint exit: $?"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"
```
Expected: actionlint prints ONLY the single pre-existing `SC2086:info` finding in the `release-android` job and nothing referencing the new Windows Store steps. `YAML OK` prints. (actionlint's exit code is non-zero because of that one pre-existing info finding — that is expected and unchanged from baseline.)

- [ ] **Step 2: Review the full Windows-job diff against the spec**

Run:
```bash
git diff origin/main -- .github/workflows/release.yml
```
Confirm against `docs/superpowers/specs/2026-06-15-windows-store-msstore-publish-design.md`:
- new `submit_for_review` input present;
- three new steps (`Check Microsoft Store credentials`, `Set up Microsoft Store Developer CLI`, `Publish MSIX to Microsoft Store`) sit between "Create GitHub Release" and "Tag store submission";
- both CLI steps gated on `steps.ms-store.outputs.enabled == 'true'`;
- publish uses `--noCommit` in the else branch only;
- build summary reports Store status.

- [ ] **Step 3: Confirm clean tree**

Run:
```bash
git status --short ; echo "(clean expected)"
git log --oneline origin/main..HEAD
```
Expected: clean working tree; four commits (Tasks 1-4) listed above `origin/main`.

---

## Done criteria

- `release.yml` has the new input + 3 gated steps + summary line; `actionlint`
  shows no new findings; YAML valid.
- `docs/windows-store-publishing.md` documents setup, secrets, and caveats.
- Feature is dormant (skips with a warning) until the four secrets are added —
  verified by the credential-guard logic, not by a live run.
- **Not covered here (follow-ups):** adding the four secrets + Partner Center
  Entra app (manual, on the operator); the first real Windows release that
  exercises the upload; wiring `submit_for_review` into iOS/macOS/Android
  (separate agent).

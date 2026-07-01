# Multi-Store Submit Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `submit_for_review` release input submit/promote builds for review on **all four stores** (Apple App Store iOS + macOS, Google Play, Microsoft Store), and add a standalone "submit an already-built release" workflow that pushes a previously-staged build to review with **no rebuild**.

**Architecture:** Keep "build" and "submit" cleanly separable. The existing `release.yml` jobs already stage each platform's binary to its store's draft/test area on every run (TestFlight, Play `internal` draft, Microsoft Store `--noCommit` draft) — that is "draft mode" and stays the default. When `submit_for_review=true`, each job runs an additional, best-effort (`continue-on-error`) **submit step** that pushes the just-staged build to review. The submit logic lives in **fastlane lanes** (iOS/macOS/Android) and a **shell script** (Windows/`msstore`) so it is reused verbatim by a new `release-submit.yml` `workflow_dispatch` that submits a chosen, already-uploaded build without rebuilding.

**Tech Stack:** GitHub Actions (`workflow_dispatch`), fastlane (`deliver`/`upload_to_app_store`, `supply`/`upload_to_play_store`), Microsoft Store Developer CLI (`msstore`), bash.

## Global Constraints

- **Two version axes, two cadences.** `CFBundleVersion` (build number, the `+N` suffix) increments on **every** build and is globally monotonic — never reset per marketing version. `CFBundleShortVersionString` (marketing version, the `X.Y.Z`) bumps **once per approved release cycle**. Apple rejects any upload whose marketing version is not strictly higher than the last *approved* one (error `90062`); Windows (MSIX `X.Y.<build>.0`) and Android (`versionCode = build`) embed the build number and have no such rule.
- **Marketing version auto-bumps after approval.** `prepare-release` queries App Store Connect for the highest already-approved marketing version across **both** the iOS and macOS platforms of app `6756905242`, and if the current `pubspec` marketing version is `<=` that, patch-bumps it (e.g. `1.5.0 -> 1.5.1`) before building. While a cycle is mid-flight (current marketing already higher than last-approved, e.g. iterating on `1.5.1` or retrying after a rejection), it leaves the version untouched — that is what lets multiple build attempts and store-rejection retries share one marketing version. The bump applies to the shared `pubspec` `version:` so all platforms stay on one consistent marketing version.
- **The approved-version query is load-bearing — fail fast, never skip.** There is intentionally no separate pre-flight check; the bump query is the single source of truth. Retry the App Store Connect query (transient network/auth blips), and if it still cannot determine the approved version, **fail `prepare-release`** with a clear message rather than proceeding without a bump (which would re-trigger `90062`).
- **Apple submit must target the right marketing version.** The iOS/macOS submit lanes pass `app_version` (from `SUBMIT_APP_VERSION`, the release's `version_name`) so `deliver` creates/submits the correct "Prepare for Submission" version rather than guessing.
- **Never deploy from a developer machine.** All store submission happens in CI (GitHub Actions). Local work is limited to editing/validating YAML, Ruby lanes, and shell scripts. (AGENTS.md: "Only work locally. Never deploy.")
- **Submit steps must be best-effort.** Every new store-submit step uses `continue-on-error: true`, mirroring the existing metadata steps, so a store-side hiccup (locked listing, build still processing, app-not-associated) never fails an otherwise-successful binary release.
- **Apple submissions default to manual release after approval.** Use `automatic_release: false` on `upload_to_app_store` so an approved build does not auto-go-live — the user retains the final go-live click. (Matches the existing unused `:release` lane.)
- **Microsoft Store product id is `9PKTCSN8SNZF`.** Verbatim everywhere `msstore` is invoked.
- **App Store Connect app id is `6756905242`; ASC team id is `0a55108e-af39-475a-a7f1-aada0c1decae`.** Used in admin links.
- **Apple export compliance + IDFA must not prompt in CI.** `ITSAppUsesNonExemptEncryption` is already present in `apps/plot/ios/Runner/Info.plist` and `apps/plot/macos/Runner/Info.plist` (handles export compliance). Every `submit_for_review: true` call MUST also pass `submission_information: { add_id_info_uses_idfa: false }` so `deliver` does not block on the IDFA question. Plot does not use the advertising identifier.
- **Apple submit must wait for the freshly-uploaded build to finish processing.** The inline (build+submit) path uploads the binary via `altool` and then submits seconds later; pass `wait_for_uploaded_build: true` so `deliver` polls App Store Connect until the build leaves "Processing" before attaching+submitting it.
- **Verification model (no runtime tests for CI).** Release workflows and fastlane lanes have no unit-test harness, so each task's "test" is static validation: `actionlint` for workflow YAML, `ruby -c` for Fastfiles, `bash -n` for scripts, and `bundle exec fastlane lanes` to confirm lane definitions parse. These are the closest equivalent to a failing/passing test cycle for this subsystem; run them before and after each change.
- **Microsoft Store one-pending-submission rule.** Partner Center allows only one in-progress submission. The Windows draft step (`msstore publish --noCommit`) deletes the prior pending submission and recreates it, so the single pending submission is always the latest build. The standalone submit, when no draft is pending, creates+commits a fresh submission from the downloaded MSIX. Never instruct a human to click "Create new submission" in Partner Center — that clones the live (old) package.

---

## File Structure

- `apps/plot/ios/fastlane/Fastfile` — add a `latest_approved_version` lane (queries App Store Connect for the highest approved marketing version across iOS+macOS) **and** a `submit` lane (selects the latest or a given build and submits for App Store review).
- `apps/plot/macos/fastlane/Fastfile` — add a `submit` lane (`platform: "osx"`).
- `apps/plot/android/fastlane/Fastfile` — generalize `promote_to_production` into a `submit_production` lane (release_status `completed`, optional `version_code`).
- `scripts/ms-store-submit.sh` — **new.** Reusable Microsoft Store submit: either commit the existing pending draft, or download an MSIX for a given version and publish+commit it. Used by the standalone workflow (the inline Windows path already commits the existing draft directly).
- `.github/workflows/release.yml` — add auto-bump-after-approval logic to `prepare-release` (query ASC, patch-bump the marketing version when `<=` last approved, before branching/building); update the `submit_for_review` input description; add inline "Submit for review" steps to `release-ios`, `release-macos`, `release-android`; update the three build summaries to reflect submit vs draft. (Windows inline submit already exists and is unchanged.)
- `.github/workflows/release-submit.yml` — **new.** `workflow_dispatch` that submits an already-staged build per store, no rebuild.
- `docs/updates.d/` — **not** touched; this is release infrastructure, not a user-facing app change (AGENTS.md updates rule explicitly excludes infra).

---

### Task 0: Auto-bump marketing version after approval

**Files:**
- Modify: `apps/plot/ios/fastlane/Fastfile` (add `latest_approved_version` lane)
- Modify: `.github/workflows/release.yml` (`prepare-release` job: add ASC auth + bump logic to the `Read current version` step, ~line "Read current version")

**Interfaces:**
- Consumes: ASC API auth — `prepare-release` runs on `ubuntu-latest` and does NOT currently set up ASC creds, so this task adds the decode (same pattern as `release-ios` ~line 187–195) and the `ASC_API_KEY_ID`/`ASC_API_ISSUER_ID` env.
- Produces: the `version` step outputs (`release_version`, `version_name`, `build_number`) now reflect the post-bump marketing version; everything downstream (branch name, build, write-back to main) consumes the bumped value unchanged. Fastlane lane `latest_approved_version` prints `LATEST_APPROVED_VERSION=<x.y.z>` (empty if the app has no approved version yet).

- [ ] **Step 1: Baseline validation**

Run:
```bash
cd /Users/kris.braun/code/plot
ruby -c apps/plot/ios/fastlane/Fastfile
actionlint .github/workflows/release.yml
```
Expected: `Syntax OK`; actionlint silent (exit 0).

- [ ] **Step 2: Add the `latest_approved_version` lane to the iOS Fastfile**

Insert near the top of `platform :ios do` (after the `:build` lane is fine):

```ruby
  desc "Print the highest already-approved App Store marketing version across iOS + macOS"
  lane :latest_approved_version do
    require "spaceship"

    token = Spaceship::ConnectAPI::Token.create(
      key_id: ENV["ASC_API_KEY_ID"],
      issuer_id: ENV["ASC_API_ISSUER_ID"],
      filepath: File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{ENV['ASC_API_KEY_ID']}.p8"),
    )
    Spaceship::ConnectAPI.token = token

    app = Spaceship::ConnectAPI::App.find("day.plot.app")
    if app.nil?
      UI.user_error!("Could not find app day.plot.app in App Store Connect")
    end

    versions = []
    [
      Spaceship::ConnectAPI::Platform::IOS,
      Spaceship::ConnectAPI::Platform::MAC_OS,
    ].each do |platform|
      # The live (READY_FOR_SALE) version is exactly what Apple compares a new
      # upload against for error 90062. nil before the first-ever release.
      live = app.get_live_app_store_version(platform: platform)
      versions << live.version_string if live && live.version_string
    end

    latest = versions.max_by { |s| Gem::Version.new(s) }
    # Stable, greppable marker for the workflow to parse.
    UI.message("LATEST_APPROVED_VERSION=#{latest}")
    latest
  end
```

- [ ] **Step 3: Validate the lane parses**

Run:
```bash
cd /Users/kris.braun/code/plot
ruby -c apps/plot/ios/fastlane/Fastfile
```
Expected: `Syntax OK`. (A live run requires real ASC creds and is exercised on the first CI run — see "Open risks".)

- [ ] **Step 4: Add ASC auth + the bump to the `prepare-release` `Read current version` step**

In `.github/workflows/release.yml`, the `prepare-release` job's `Read current version` step (id `version`) currently reads `pubspec` and emits outputs. Replace that step with the version below, which (a) installs fastlane + decodes the ASC key, (b) queries the latest approved version with retries, (c) patch-bumps `VERSION_NAME` when it is `<=` the approved version, and (d) emits the (possibly bumped) outputs. Add the job-level env `ASC_API_KEY_ID` / `ASC_API_ISSUER_ID` to `prepare-release` as well.

Add to the `prepare-release` job, at the job level (a `env:` block on the job, mirroring `release-ios` lines 156–158):

```yaml
    env:
      ASC_API_KEY_ID: ${{ secrets.ASC_API_KEY_ID }}
      ASC_API_ISSUER_ID: ${{ secrets.ASC_API_ISSUER_ID }}
```

Replace the `Read current version` step with:

```yaml
      - name: Set up Ruby + fastlane (for ASC version query)
        run: sudo gem install fastlane --no-document

      - name: Write ASC API key
        env:
          ASC_API_KEY_P8_BASE64: ${{ secrets.ASC_API_KEY_P8_BASE64 }}
        run: |
          mkdir -p ~/.appstoreconnect/private_keys
          echo "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
          chmod 0600 "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"

      - name: Read current version and auto-bump marketing version after approval
        id: version
        run: |
          set -euo pipefail
          cd apps/plot
          RELEASE_VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //' | tr -d ' ')
          VERSION_NAME=$(echo "$RELEASE_VERSION" | cut -d'+' -f1)
          BUILD_NUMBER=$(echo "$RELEASE_VERSION" | cut -d'+' -f2)

          # Query App Store Connect for the highest already-approved marketing
          # version across iOS + macOS. The query is load-bearing (no separate
          # pre-flight check): retry transient failures, then fail the release if
          # it never succeeds, rather than risk Apple error 90062. An empty
          # APPROVED after a SUCCESSFUL lane run means "no approved version yet"
          # (brand-new app) — a valid no-bump case.
          APPROVED=""
          QUERY_OK=false
          for attempt in 1 2 3 4 5; do
            if OUT=$(cd ios && fastlane latest_approved_version 2>&1); then
              APPROVED=$(echo "$OUT" | sed -ne 's/.*LATEST_APPROVED_VERSION=\([0-9][0-9.]*\).*/\1/p' | tail -1)
              QUERY_OK=true
              break
            fi
            echo "ASC version query attempt $attempt failed; retrying in $((attempt * 10))s..." >&2
            sleep "$((attempt * 10))"
          done

          if [ "$QUERY_OK" != "true" ]; then
            echo "ERROR: could not reach App Store Connect to determine the approved version. Aborting to avoid Apple error 90062." >&2
            exit 1
          fi

          # Bump VERSION_NAME to APPROVED's patch+1 when the current marketing
          # version is not strictly higher than the approved one.
          if [ -n "$APPROVED" ]; then
            higher=$(printf '%s\n%s\n' "$APPROVED" "$VERSION_NAME" | sort -V | tail -1)
            if [ "$VERSION_NAME" = "$APPROVED" ] || [ "$higher" = "$APPROVED" ]; then
              IFS='.' read -r MA MI PA <<< "$APPROVED"
              VERSION_NAME="${MA}.${MI}.$((PA + 1))"
              echo "Marketing version <= approved ($APPROVED); bumped to $VERSION_NAME"
            else
              echo "Marketing version $VERSION_NAME already > approved ($APPROVED); no bump"
            fi
          else
            echo "No approved App Store version found; keeping $VERSION_NAME"
          fi

          RELEASE_VERSION="${VERSION_NAME}+${BUILD_NUMBER}"
          {
            echo "release_version=$RELEASE_VERSION"
            echo "version_name=$VERSION_NAME"
            echo "build_number=$BUILD_NUMBER"
            echo "release_branch=release/$RELEASE_VERSION"
          } >> "$GITHUB_OUTPUT"

          echo "Release version: $RELEASE_VERSION"
```

Note for the implementer: the existing `Stamp changelog and bump main` step already writes `${VERSION_NAME}+${NEXT_BUILD_NUMBER}` back to `main` using `steps.version.outputs.version_name`, so the bumped marketing version propagates to `main` automatically — no change needed there. Verify that step references `steps.version.outputs.version_name` (it does at ~line "NEXT_VERSION").

- [ ] **Step 5: Validate the workflow**

Run:
```bash
cd /Users/kris.braun/code/plot
actionlint .github/workflows/release.yml
```
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/ios/fastlane/Fastfile .github/workflows/release.yml
git commit -m "feat(release): auto-bump marketing version when <= last App Store approved version"
```

---

### Task 1: iOS inline submit-for-review

**Files:**
- Modify: `apps/plot/ios/fastlane/Fastfile` (add `submit` lane after the `release` lane, ~line 140)
- Modify: `.github/workflows/release.yml` (add a step in `release-ios` immediately after `Upload to App Store Connect`, ~line 409, before `Upload metadata and screenshots`)

**Interfaces:**
- Consumes: ASC API auth via env (`ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `~/.appstoreconnect/private_keys/AuthKey_<id>.p8`) — already set on the `release-ios` job.
- Produces: iOS fastlane lane `submit` that honors optional `SUBMIT_BUILD_NUMBER` env to target a specific build (used by Task 6); when unset, `deliver` selects the latest processed build. This same lane name/contract is reused by macOS as `submit` (Task 2, different platform) and by the standalone workflow (Task 6).

- [ ] **Step 1: Capture the pre-change validation baseline**

Run:
```bash
cd /Users/kris.braun/code/plot
ruby -c apps/plot/ios/fastlane/Fastfile
actionlint .github/workflows/release.yml
```
Expected: `Syntax OK` for the Fastfile; actionlint prints nothing (exit 0). This is the green baseline the change must preserve.

- [ ] **Step 2: Add the `submit` lane to the iOS Fastfile**

Insert after the `:release` lane (before `lane :test`):

```ruby
  desc "Submit an already-uploaded build to App Store review (no binary upload)"
  lane :submit do
    options = {
      skip_binary_upload: true,
      skip_metadata: true,
      skip_screenshots: true,
      submit_for_review: true,
      # User retains the go-live click after approval (see plan Global Constraints).
      automatic_release: false,
      force: true,
      # The inline path submits seconds after altool upload; wait for App Store
      # Connect to finish processing the build before attaching + submitting it.
      wait_for_uploaded_build: true,
      precheck_include_in_app_purchases: false,
      # Plot does not use the advertising identifier; answer the IDFA question
      # non-interactively so deliver never blocks in CI.
      submission_information: { add_id_info_uses_idfa: false },
    }

    # Target a specific build when asked (standalone submit workflow), else
    # deliver picks the latest processed build for the current version.
    options[:build_number] = ENV["SUBMIT_BUILD_NUMBER"] if ENV["SUBMIT_BUILD_NUMBER"] && !ENV["SUBMIT_BUILD_NUMBER"].empty?
    # Target the right "Prepare for Submission" marketing version (deliver
    # creates it if needed) rather than letting deliver guess.
    options[:app_version] = ENV["SUBMIT_APP_VERSION"] if ENV["SUBMIT_APP_VERSION"] && !ENV["SUBMIT_APP_VERSION"].empty?

    if ENV["ASC_API_KEY_ID"] && ENV["ASC_API_ISSUER_ID"]
      options[:api_key] = app_store_connect_api_key(
        key_id: ENV["ASC_API_KEY_ID"],
        issuer_id: ENV["ASC_API_ISSUER_ID"],
        key_filepath: File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{ENV['ASC_API_KEY_ID']}.p8")
      )
    end

    upload_to_app_store(options)

    UI.success("iOS build submitted for App Store review!")
  end
```

- [ ] **Step 3: Validate the lane parses**

Run:
```bash
cd /Users/kris.braun/code/plot
ruby -c apps/plot/ios/fastlane/Fastfile
cd apps/plot/ios && bundle exec fastlane lanes 2>&1 | grep -A1 ':submit' ; cd /Users/kris.braun/code/plot
```
Expected: `Syntax OK`; `fastlane lanes` lists the new `submit` lane with its description. (If `bundle exec` is unavailable locally, `ruby -c` passing is sufficient.)

- [ ] **Step 4: Add the inline submit step to `release-ios`**

Insert immediately after the `Upload to App Store Connect` step (the one ending in `--apiIssuer "$ASC_API_ISSUER_ID"`), before the `Upload metadata and screenshots to App Store Connect` step:

```yaml
      # When submit_for_review is set, push the just-uploaded build to App Store
      # review. Best-effort (continue-on-error): the binary is already in
      # TestFlight, so a review-submission hiccup (build still processing, a
      # version already In Review, missing compliance answers) must not fail the
      # release. wait_for_uploaded_build inside the lane bridges the altool
      # processing delay.
      - name: Submit to App Store for review
        id: submit
        if: ${{ inputs.submit_for_review }}
        continue-on-error: true
        env:
          SUBMIT_APP_VERSION: ${{ needs.prepare-release.outputs.version_name }}
        run: |
          cd apps/plot/ios
          fastlane submit
```

- [ ] **Step 5: Validate the workflow**

Run:
```bash
cd /Users/kris.braun/code/plot
actionlint .github/workflows/release.yml
```
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/ios/fastlane/Fastfile .github/workflows/release.yml
git commit -m "feat(release): submit iOS build for App Store review when submit_for_review"
```

---

### Task 2: macOS inline submit-for-review

**Files:**
- Modify: `apps/plot/macos/fastlane/Fastfile` (add `submit` lane after `release_mas`)
- Modify: `.github/workflows/release.yml` (add a step in `release-macos` after `Upload to App Store Connect`, ~line 1034, before the metadata step)

**Interfaces:**
- Consumes: ASC API auth env on the `release-macos` job (same secrets as iOS; `release-macos` already sets `ASC_API_KEY_ID`/`ASC_API_ISSUER_ID` at ~line 777).
- Produces: macOS fastlane lane `submit` (identical contract to iOS `submit` but with `platform: "osx"`). Reused by Task 6.

- [ ] **Step 1: Baseline validation**

Run:
```bash
cd /Users/kris.braun/code/plot
ruby -c apps/plot/macos/fastlane/Fastfile
```
Expected: `Syntax OK`.

- [ ] **Step 2: Add the `submit` lane to the macOS Fastfile**

Insert after the `:release_mas` lane (before `:release_dmg`):

```ruby
  desc "Submit an already-uploaded build to Mac App Store review (no binary upload)"
  lane :submit do
    options = {
      skip_binary_upload: true,
      skip_metadata: true,
      skip_screenshots: true,
      submit_for_review: true,
      automatic_release: false,
      force: true,
      wait_for_uploaded_build: true,
      precheck_include_in_app_purchases: false,
      submission_information: { add_id_info_uses_idfa: false },
      platform: "osx",
    }

    options[:build_number] = ENV["SUBMIT_BUILD_NUMBER"] if ENV["SUBMIT_BUILD_NUMBER"] && !ENV["SUBMIT_BUILD_NUMBER"].empty?
    options[:app_version] = ENV["SUBMIT_APP_VERSION"] if ENV["SUBMIT_APP_VERSION"] && !ENV["SUBMIT_APP_VERSION"].empty?

    if ENV["ASC_API_KEY_ID"] && ENV["ASC_API_ISSUER_ID"]
      options[:api_key] = app_store_connect_api_key(
        key_id: ENV["ASC_API_KEY_ID"],
        issuer_id: ENV["ASC_API_ISSUER_ID"],
        key_filepath: File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{ENV['ASC_API_KEY_ID']}.p8")
      )
    end

    upload_to_app_store(options)

    UI.success("macOS build submitted for Mac App Store review!")
  end
```

- [ ] **Step 3: Validate the lane parses**

Run:
```bash
cd /Users/kris.braun/code/plot
ruby -c apps/plot/macos/fastlane/Fastfile
```
Expected: `Syntax OK`.

- [ ] **Step 4: Add the inline submit step to `release-macos`**

Insert immediately after the macOS `Upload to App Store Connect` step (ending in `--apiIssuer "$ASC_API_ISSUER_ID"`), before the metadata step:

```yaml
      - name: Submit to Mac App Store for review
        id: submit
        if: ${{ inputs.submit_for_review }}
        continue-on-error: true
        env:
          SUBMIT_APP_VERSION: ${{ needs.prepare-release.outputs.version_name }}
        run: |
          cd apps/plot/macos
          fastlane submit
```

- [ ] **Step 5: Validate the workflow**

Run:
```bash
cd /Users/kris.braun/code/plot
actionlint .github/workflows/release.yml
```
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/macos/fastlane/Fastfile .github/workflows/release.yml
git commit -m "feat(release): submit macOS build for Mac App Store review when submit_for_review"
```

---

### Task 3: Android inline production submit

**Files:**
- Modify: `apps/plot/android/fastlane/Fastfile` (replace `promote_to_production` with a generalized `submit_production` lane)
- Modify: `.github/workflows/release.yml` (add a step in `release-android` after `Upload to Google Play (internal testing)`, ~line 689)

**Interfaces:**
- Consumes: Play auth via the Appfile's `json_key_file("./play-deployer-service-key.json")` (the `release-android` job decodes `PLAY_STORE_SERVICE_KEY` to that path before this runs).
- Produces: Android fastlane lane `submit_production` honoring optional `SUBMIT_VERSION_CODE` env (the AAB's version code == build number) to promote a specific build; when unset, promotes the latest internal release. Reused by Task 6.

- [ ] **Step 1: Baseline validation**

Run:
```bash
cd /Users/kris.braun/code/plot
ruby -c apps/plot/android/fastlane/Fastfile
```
Expected: `Syntax OK`.

- [ ] **Step 2: Replace `promote_to_production` with `submit_production`**

Replace the entire existing `promote_to_production` lane:

```ruby
  desc "Promote beta to production"
  lane :promote_to_production do
    upload_to_play_store(
      track: 'internal',
      track_promote_to: 'production',
      skip_upload_apk: true,
      skip_upload_aab: true,
      skip_upload_metadata: true,
      skip_upload_images: true,
      skip_upload_screenshots: true
    )

    UI.success("Beta promoted to production!")
  end
```

with:

```ruby
  desc "Promote the internal-testing build to Production for review (submit)"
  lane :submit_production do
    options = {
      track: 'internal',
      track_promote_to: 'production',
      # 'completed' submits the production release for review / rollout; the
      # internal 'beta' upload stages it as 'draft' first (see :beta lane).
      release_status: 'completed',
      skip_upload_apk: true,
      skip_upload_aab: true,
      skip_upload_metadata: true,
      skip_upload_images: true,
      skip_upload_screenshots: true,
    }

    # Promote a specific build when asked (standalone submit workflow); else
    # supply promotes the latest release currently on the internal track.
    if ENV["SUBMIT_VERSION_CODE"] && !ENV["SUBMIT_VERSION_CODE"].empty?
      options[:version_code] = ENV["SUBMIT_VERSION_CODE"].to_i
    end

    upload_to_play_store(options)

    UI.success("Android build promoted to Google Play Production for review!")
  end
```

- [ ] **Step 3: Validate the lane parses**

Run:
```bash
cd /Users/kris.braun/code/plot
ruby -c apps/plot/android/fastlane/Fastfile
```
Expected: `Syntax OK`.

- [ ] **Step 4: Add the inline submit step to `release-android`**

Insert immediately after the `Upload to Google Play (internal testing)` step, before the `Upload metadata and screenshots to Google Play` step:

```yaml
      # When submit_for_review is set, promote the build just uploaded to the
      # internal track up to Production (release_status completed => submitted
      # for review). Best-effort: the AAB is already on internal testing, so a
      # promotion hiccup (a halted rollout, changes pending review) must not
      # fail the release.
      - name: Promote to Google Play production
        id: submit
        if: ${{ inputs.submit_for_review }}
        continue-on-error: true
        run: |
          cd apps/plot/android
          fastlane submit_production
```

- [ ] **Step 5: Validate the workflow**

Run:
```bash
cd /Users/kris.braun/code/plot
actionlint .github/workflows/release.yml
```
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/android/fastlane/Fastfile .github/workflows/release.yml
git commit -m "feat(release): promote Android to production for review when submit_for_review"
```

---

### Task 4: Microsoft Store submit script (for the standalone workflow)

**Files:**
- Create: `scripts/ms-store-submit.sh`

**Interfaces:**
- Consumes: a configured `msstore` CLI (caller runs `msstore reconfigure` first), the env var `R2_PUBLIC_BASE` (defaults to `https://download.plot.day`), and a single positional arg: the release version (e.g. `1.5.0+373`) OR empty to commit the existing pending draft.
- Produces: a committed Microsoft Store submission (`msstore submission publish 9PKTCSN8SNZF`). The inline Windows release path does NOT use this script (it commits the existing draft directly, unchanged); only the standalone workflow (Task 6) calls it.

- [ ] **Step 1: Write the script**

Create `scripts/ms-store-submit.sh`:

```bash
#!/usr/bin/env bash
# Submit (commit) a Microsoft Store submission for Plot (product 9PKTCSN8SNZF).
#
# Usage:
#   ms-store-submit.sh                 # commit the existing pending draft
#   ms-store-submit.sh 1.5.0+373       # download that release's MSIX, create a
#                                      # fresh submission with it, and commit
#
# Requires `msstore` to be installed and already configured via
# `msstore reconfigure` (the caller does this with the Azure AD secrets).
set -euo pipefail

PRODUCT_ID="9PKTCSN8SNZF"
VERSION="${1:-}"
R2_PUBLIC_BASE="${R2_PUBLIC_BASE:-https://download.plot.day}"

if [ -n "$VERSION" ]; then
  MSIX_FILE="Plot-${VERSION}.msix"
  URL="${R2_PUBLIC_BASE}/releases/${VERSION}/windows/${MSIX_FILE}"
  echo "Downloading ${URL}"
  curl -fSL "$URL" -o "$MSIX_FILE"
  # publish WITHOUT --noCommit creates a new submission AND commits it for
  # certification in one step. msstore deletes any existing pending draft first.
  msstore publish "$MSIX_FILE" -id "$PRODUCT_ID" --verbose
else
  echo "Committing existing pending submission for ${PRODUCT_ID}"
  msstore submission publish "$PRODUCT_ID"
fi

echo "Microsoft Store submission committed."
```

- [ ] **Step 2: Make it executable and syntax-check**

Run:
```bash
cd /Users/kris.braun/code/plot
chmod +x scripts/ms-store-submit.sh
bash -n scripts/ms-store-submit.sh && echo "bash syntax OK"
```
Expected: `bash syntax OK`.

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot
git add scripts/ms-store-submit.sh
git commit -m "feat(release): add reusable Microsoft Store submit script"
```

---

### Task 5: Update input description and per-store build summaries

**Files:**
- Modify: `.github/workflows/release.yml` (input description ~line 23; iOS summary ~line 478; Android summary ~line 745; macOS summary ~line 1097)

**Interfaces:**
- Consumes: `steps.submit.outcome` from the submit steps added in Tasks 1–3 (each submit step has `id: submit`).
- Produces: nothing downstream; cosmetic/diagnostic only.

- [ ] **Step 1: Update the `submit_for_review` input description**

Replace:
```yaml
      submit_for_review:
        description: 'Submit uploaded store builds for review/certification (currently Windows only; off = upload as draft)'
        type: boolean
        default: false
```
with:
```yaml
      submit_for_review:
        description: 'Submit uploaded builds for review on every released store (Apple App Store iOS+macOS, Google Play production, Microsoft Store); off = stage as draft (TestFlight / Play internal / Store draft) to finish by hand'
        type: boolean
        default: false
```

- [ ] **Step 2: Update the iOS build summary**

Replace the iOS summary's `**Uploaded to:**` line:
```yaml
            echo "**Uploaded to:** App Store Connect (TestFlight)"
```
with:
```yaml
            echo "**Uploaded to:** App Store Connect (TestFlight)"
            echo "**Review submission:** ${{ inputs.submit_for_review && (steps.submit.outcome == 'success' && 'submitted for App Store review' || 'submit FAILED — see the Submit step logs (build may still be processing or a version is already In Review)') || 'not requested (TestFlight only; submit by hand in App Store Connect)' }}"
```

- [ ] **Step 3: Update the Android build summary**

Replace the Android summary's `**Uploaded to:**` line:
```yaml
            echo "**Uploaded to:** Google Play (internal testing)"
```
with:
```yaml
            echo "**Uploaded to:** Google Play (internal testing)"
            echo "**Review submission:** ${{ inputs.submit_for_review && (steps.submit.outcome == 'success' && 'promoted to Production for review' || 'promote FAILED — see the Promote step logs (rollout may be halted or changes pending review)') || 'not requested (internal testing only; promote by hand in Play Console)' }}"
```

- [ ] **Step 4: Update the macOS build summary**

Find the macOS summary `**Uploaded to:**` line (`echo "**Uploaded to:** App Store Connect"`) and add a review-submission line after it:
```yaml
            echo "**Uploaded to:** App Store Connect"
            echo "**Review submission:** ${{ inputs.submit_for_review && (steps.submit.outcome == 'success' && 'submitted for Mac App Store review' || 'submit FAILED — see the Submit step logs (build may still be processing or a version is already In Review)') || 'not requested (TestFlight only; submit by hand in App Store Connect)' }}"
```

- [ ] **Step 5: Validate the workflow**

Run:
```bash
cd /Users/kris.braun/code/plot
actionlint .github/workflows/release.yml
```
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add .github/workflows/release.yml
git commit -m "docs(release): describe all-store submit_for_review and report submit status in summaries"
```

---

### Task 6: Standalone "submit already-built release" workflow

**Files:**
- Create: `.github/workflows/release-submit.yml`

**Interfaces:**
- Consumes: the fastlane lanes `submit` (iOS), `submit` (macOS), `submit_production` (Android) from Tasks 1–3, and `scripts/ms-store-submit.sh` from Task 4. Reuses the same store secrets the release jobs use (`ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`, `PLAY_STORE_SERVICE_KEY`, `AZURE_AD_*`, `SELLER_ID`).
- Produces: nothing downstream.

**Notes for the implementer:**
- iOS/macOS/Android submit jobs are **pure App Store Connect / Play API calls** (no Xcode/Gradle build), so they run on `ubuntu-latest` with just fastlane installed. Windows submit needs `msstore`, so it runs on `windows-latest`.
- The build to submit must already have been uploaded by a prior `release.yml` run. For Apple, pass the build number; for Android, the version code (== build number); for Windows, the release version so the MSIX can be re-downloaded from R2 and published fresh.

- [ ] **Step 1: Create the workflow**

Create `.github/workflows/release-submit.yml`:

```yaml
name: Submit Release (no rebuild)

# Submits an ALREADY-BUILT release to each store for review/certification,
# without rebuilding. Use after a draft release run (submit_for_review=false)
# once you have finished reviewing the staged listing on each store, or to
# re-submit after fixing listing text. The binary must already be uploaded by a
# prior Release run (TestFlight / Play internal / Microsoft Store draft).

on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Full release version to submit, e.g. 1.5.0+373. Marketing version (1.5.0) and build number (373) are derived from it.'
        type: string
        required: true
      ios:
        description: 'Submit iOS to App Store review'
        type: boolean
        default: false
      macos:
        description: 'Submit macOS to Mac App Store review'
        type: boolean
        default: false
      android:
        description: 'Promote Android to Google Play production (review)'
        type: boolean
        default: false
      windows:
        description: 'Submit Windows to Microsoft Store certification'
        type: boolean
        default: false

concurrency:
  group: native-release
  cancel-in-progress: false

jobs:
  submit-ios:
    if: inputs.ios
    runs-on: ubuntu-latest
    env:
      ASC_API_KEY_ID: ${{ secrets.ASC_API_KEY_ID }}
      ASC_API_ISSUER_ID: ${{ secrets.ASC_API_ISSUER_ID }}
    steps:
      - uses: actions/checkout@v7
      - name: Install fastlane
        run: sudo gem install fastlane --no-document
      - name: Write ASC API key
        env:
          ASC_API_KEY_P8_BASE64: ${{ secrets.ASC_API_KEY_P8_BASE64 }}
        run: |
          mkdir -p ~/.appstoreconnect/private_keys
          echo "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
          chmod 0600 "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
      - name: Submit to App Store for review
        run: |
          VERSION="${{ inputs.version }}"
          export SUBMIT_APP_VERSION="${VERSION%%+*}"
          export SUBMIT_BUILD_NUMBER="${VERSION##*+}"
          cd apps/plot/ios
          fastlane submit

  submit-macos:
    if: inputs.macos
    runs-on: ubuntu-latest
    env:
      ASC_API_KEY_ID: ${{ secrets.ASC_API_KEY_ID }}
      ASC_API_ISSUER_ID: ${{ secrets.ASC_API_ISSUER_ID }}
    steps:
      - uses: actions/checkout@v7
      - name: Install fastlane
        run: sudo gem install fastlane --no-document
      - name: Write ASC API key
        env:
          ASC_API_KEY_P8_BASE64: ${{ secrets.ASC_API_KEY_P8_BASE64 }}
        run: |
          mkdir -p ~/.appstoreconnect/private_keys
          echo "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
          chmod 0600 "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
      - name: Submit to Mac App Store for review
        run: |
          VERSION="${{ inputs.version }}"
          export SUBMIT_APP_VERSION="${VERSION%%+*}"
          export SUBMIT_BUILD_NUMBER="${VERSION##*+}"
          cd apps/plot/macos
          fastlane submit

  submit-android:
    if: inputs.android
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Install fastlane
        run: sudo gem install fastlane --no-document
      - name: Write Play service key
        env:
          PLAY_STORE_SERVICE_KEY: ${{ secrets.PLAY_STORE_SERVICE_KEY }}
        run: |
          echo "$PLAY_STORE_SERVICE_KEY" | base64 --decode > "$GITHUB_WORKSPACE/apps/plot/android/play-deployer-service-key.json"
      - name: Promote to Google Play production
        run: |
          VERSION="${{ inputs.version }}"
          export SUBMIT_VERSION_CODE="${VERSION##*+}"
          cd apps/plot/android
          fastlane submit_production

  submit-windows:
    if: inputs.windows
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v7
      - name: Set up Microsoft Store Developer CLI
        uses: microsoft/setup-msstore-cli@v1.3
      - name: Configure Microsoft Store CLI
        shell: bash
        env:
          AZURE_AD_TENANT_ID: ${{ secrets.AZURE_AD_TENANT_ID }}
          SELLER_ID: ${{ secrets.SELLER_ID }}
          AZURE_AD_APPLICATION_CLIENT_ID: ${{ secrets.AZURE_AD_APPLICATION_CLIENT_ID }}
          AZURE_AD_APPLICATION_SECRET: ${{ secrets.AZURE_AD_APPLICATION_SECRET }}
        run: |
          msstore reconfigure \
            --tenantId "$AZURE_AD_TENANT_ID" \
            --sellerId "$SELLER_ID" \
            --clientId "$AZURE_AD_APPLICATION_CLIENT_ID" \
            --clientSecret "$AZURE_AD_APPLICATION_SECRET"
      - name: Submit Windows MSIX to Microsoft Store
        shell: bash
        run: |
          bash "$GITHUB_WORKSPACE/scripts/ms-store-submit.sh" "${{ inputs.version }}"
```

- [ ] **Step 2: Validate the new workflow**

Run:
```bash
cd /Users/kris.braun/code/plot
actionlint .github/workflows/release-submit.yml
```
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot
git add .github/workflows/release-submit.yml
git commit -m "feat(release): add standalone submit-already-built-release workflow"
```

---

### Task 7: Finalize

**Files:** none (validation only)

- [ ] **Step 1: Validate every changed/created file**

Run:
```bash
cd /Users/kris.braun/code/plot
actionlint .github/workflows/release.yml .github/workflows/release-submit.yml
ruby -c apps/plot/ios/fastlane/Fastfile
ruby -c apps/plot/macos/fastlane/Fastfile
ruby -c apps/plot/android/fastlane/Fastfile
bash -n scripts/ms-store-submit.sh
```
Expected: actionlint silent (exit 0); three `Syntax OK`; script syntax silent.

- [ ] **Step 2: Confirm the inline Windows path is untouched and still gated correctly**

Run:
```bash
cd /Users/kris.braun/code/plot
grep -n 'msstore submission publish 9PKTCSN8SNZF' .github/workflows/release.yml
grep -n 'if: steps.ms-store.outputs.enabled == .true. && inputs.submit_for_review' .github/workflows/release.yml
```
Expected: the existing Windows submit step and its `inputs.submit_for_review` gate are both still present (this plan does not modify them).

- [ ] **Step 3: Run the finalize checklist**

Per AGENTS.md, run `/finalize`. Lint is N/A for YAML/Ruby/bash here (covered by actionlint/ruby -c/bash -n above); confirm no `docs/updates.d/` fragment is needed (infra change, excluded by the updates rule); confirm no `public/` submodule changes.

- [ ] **Step 4: Push the branch and open a PR**

```bash
cd /Users/kris.braun/code/plot
git push -u origin HEAD
gh pr create --title "Multi-store submit flow + standalone submit workflow" --body "<summary of the three requirements and how each store is handled>"
```

---

## Self-Review

**1. Spec coverage:**
- Req #1 (build drafts, review per site): unchanged default behavior — iOS/macOS→TestFlight, Android→Play internal draft, Windows→Store `--noCommit` draft. ✓ (documented in Task 5 input description; no code needed beyond what exists).
- Req #2 (submit to all directly): Tasks 1 (iOS), 2 (macOS), 3 (Android), and the pre-existing Windows submit step, all gated on `submit_for_review`. ✓
- Req #3 (draft always latest): each release run re-stages the latest binary (TestFlight add, Play internal draft, Store `--noCommit` replace). Documented in Global Constraints; the Windows UI-clone gotcha is called out so the human always opens the CI-staged submission. ✓
- Versioning reqs (unique version / multiple attempts / retry-until-pass / Apple's rules): Task 0 auto-bumps the marketing version only when `<=` last-approved, leaving it stable during a cycle. ✓
- Standalone no-rebuild submit (user-requested): Task 6. ✓

**2. Placeholder scan:** No TBD/TODO; every lane and step shows complete code. The PR body in Task 7 Step 4 is intentionally author-supplied at PR time (not a code placeholder).

**3. Type/name consistency:** iOS lane `submit`, macOS lane `submit`, Android lane `submit_production`, script `scripts/ms-store-submit.sh`, submit step `id: submit` — all referenced consistently across Tasks 1–6. Env contract names (`SUBMIT_BUILD_NUMBER`, `SUBMIT_VERSION_CODE`) match between the lanes (Tasks 1–3) and the standalone workflow (Task 6). Microsoft product id `9PKTCSN8SNZF` consistent. ✓

## Open risks to verify on first real run
- **Spaceship API surface (Task 0):** `app.get_live_app_store_version(platform:)`, `Spaceship::ConnectAPI::Token.create`, and `Platform::IOS/MAC_OS` are stable fastlane APIs, but the exact method names can drift across fastlane majors. The lane is only `ruby -c`-checked locally (a live run needs real ASC creds); verify against the runner's fastlane version on the first `prepare-release` run. If `get_live_app_store_version` is unavailable, fall back to `app.get_app_store_versions` filtered to `READY_FOR_SALE`.
- **Marketing bump adds ~1–2 min to `prepare-release`** (fastlane install + ASC query). Acceptable; it gates every release.
- **Apple build-processing latency:** `wait_for_uploaded_build: true` should bridge it, but the first inline `submit_for_review=true` run may take extra minutes while `deliver` polls. If it times out, fall back to the standalone workflow once processing completes.
- **Android promote source:** `submit_production` promotes from `internal`; the `:beta` lane stages internal as `release_status: 'draft'`. Confirm on the first run that a draft internal release can be promoted to `completed` production in one supply call; if Play rejects promoting a draft, change `:beta` to `release_status: 'completed'` for internal or add an intermediate completion.
- **`automatic_release: false`:** approved Apple builds wait for a manual go-live click — intended, but confirm the user wants manual rather than automatic release after approval.

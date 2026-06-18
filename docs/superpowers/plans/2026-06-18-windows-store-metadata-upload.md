# Windows Store listing-metadata upload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Push the Windows Microsoft Store listing text (description, short description, features, search terms) from committed source files during the `release-windows` job, reaching metadata parity with the iOS/Android/macOS release steps.

**Architecture:** Migrate the hand-maintained Windows copy out of `docs/store-listings.md` into dedicated per-field source files under `apps/plot/windows/store/en-US/`. In `release.yml`, split the existing single Microsoft-Store publish step into four gated steps: configure → publish the MSIX as a draft (`--noCommit`) → fetch the draft submission JSON, patch only the text fields with `jq` (leaving images and everything else intact), `submission updateMetadata` → conditionally `submission publish` to commit package + metadata together.

**Tech Stack:** GitHub Actions (`release-windows` job, `windows-2022`, `shell: bash` / git-bash), Microsoft Store Developer CLI (`msstore`), `jq` (pre-installed on GitHub runners), `awk`.

## Global Constraints

- **Product ID:** `9PKTCSN8SNZF` (Plot in Partner Center) — reuse this literal, already present in the job.
- **DevCenter submission is full-replace:** `msstore submission updateMetadata` for a Packaged (MSIX) product replaces the entire submission. Always fetch-patch-push the whole object; never send a partial. Patch ONLY `description`, `shortDescription`, `features`, `keywords`; leave `images` and all other fields untouched.
- **JSON keys are camelCase:** `description`, `shortDescription`, `features`, `keywords`, `images`, `baseListing`, `listings`.
- **Field limits (do not exceed when editing copy):** description ≤ 10,000 chars; features ≤ 20 items, ≤ 200 chars each; search terms ≤ 7 items, ≤ 30 chars each.
- **Free products only:** the CLI errors and deletes the submission on a paid product. Plot's listing is free — precondition, not enforced here.
- **All Store steps stay gated** on `steps.ms-store.outputs.enabled == 'true'` (the existing credential check). The metadata + submit steps are additionally `continue-on-error: true`.
- **Workspace:** localized change — work in the main repo folder on the current branch (`last-minute-fixes`). No worktree, no branch switch.
- **No `docs/updates.md` entry** — internal CI/infra change.

---

### Task 1: Windows Store listing source files

Create the four per-field source files, migrated verbatim from the Microsoft Store section of `docs/store-listings.md` (lines ~369–444). These are the source of truth the workflow reads.

**Files:**
- Create: `apps/plot/windows/store/en-US/description.txt`
- Create: `apps/plot/windows/store/en-US/short_description.txt`
- Create: `apps/plot/windows/store/en-US/features.txt`
- Create: `apps/plot/windows/store/en-US/search_terms.txt`

**Interfaces:**
- Produces: four UTF-8 text files. `description.txt` (free text), `short_description.txt` (1 line), `features.txt` (10 lines, one feature each), `search_terms.txt` (7 lines, one term each). The metadata step in Task 2 reads them via `jq --rawfile`.

- [ ] **Step 1: Create `description.txt`** with exactly this content (UTF-8; note the `•` bullets and `—` em-dashes):

```
Your most important work isn't the newest email or the loudest notification. It's scattered across a dozen apps, mixed in with everything else competing for your attention. Plot brings it together, organized around the roles and goals you care about, so you can choose a focus and make real progress.

Reply, react, assign, and finish work in one place — across team chat, email, meeting notes, and the comment threads inside the tools you already use — without opening five apps full of distractions.

Plot also protects your attention. Low-signal mail — newsletters, receipts, promotions — waits in a muted FYI focus instead of pinging you, and you decide when notifications are allowed. Genuinely urgent threads still break through; the rest of your day stays yours.

WHAT YOU CAN DO
• Bring team chat, email, meeting notes, and app comments into one organized list
• Reply, react, comment, and change status without leaving Plot
• Mark anything To do, schedule it for later, or finish it — so nothing gets dropped
• Group your work under roles and focuses, so the right things get your best attention
• Let low-signal mail — newsletters, receipts, promotions — wait in a muted FYI focus instead of pinging you
• Set when interruptions are allowed; genuinely urgent threads still break through
• See your whole day — calendar events and scheduled work — on one agenda
• Search across everything, wherever it came from
• Use AI right alongside your work, as much or as little as you like — or turn it off entirely

MADE FOR WINDOWS
Native desktop notifications that quiet down when the app is in front of you and respect your Focus assist settings. A keyboard-driven command bar for getting around fast. Light, dark, or system — it follows Windows.

WORKS WITH YOUR TOOLS
Connect Gmail, Google Calendar, Google Chat, Outlook Calendar, Microsoft Teams, Slack, Linear, Notion, PostHog, and Apple Calendar. WhatsApp, Instagram, and LinkedIn messaging are available too. Read and reply in one place; jump to the source whenever you need it.

WORKS OFFLINE, ON EVERY DEVICE
Read, write, organize, and finish work with no connection — everything syncs the moment you're back online. Plot runs on Windows, Mac, iPhone, iPad, Android, and the web, with a consistent experience and platform-native touches.

WORK YOUR WAY
Use AI as much or as little as you want — bring your own key, point it at your own model, or turn it off entirely. Your data stays yours: you connect each account securely without handing Plot your passwords, your data is encrypted in transit, and only you and the people you share with can see it.

Plot has a free plan. Get back to your best work.
```

- [ ] **Step 2: Create `short_description.txt`** with exactly one line:

```
Team chat, email, meeting notes, and threads from your apps, organized around your priorities.
```

- [ ] **Step 3: Create `features.txt`** (exactly 10 lines, one feature per line):

```
Team chat, email, and app comment threads in one organized place
Reply, react, and change status without leaving Plot
Mark anything To do, schedule it for later, or finish it
Group your work under roles and focuses so the right things get your attention
Low-signal mail waits in a muted FYI focus instead of interrupting you
Notifications on your schedule, with genuinely urgent threads breaking through
One agenda for your calendar events and scheduled work
Search across every connection, focus, and thread
Use AI alongside your work, as much or as little as you like — or turn it off
Works offline and syncs across all your devices
```

- [ ] **Step 4: Create `search_terms.txt`** (exactly 7 lines, one term per line):

```
email client
team chat
task manager
calendar
productivity
collaboration
inbox
```

- [ ] **Step 5: Verify shape and limits**

Run:
```bash
cd /Users/kris.braun/code/plot
SRC=apps/plot/windows/store/en-US
echo "description bytes: $(wc -c < $SRC/description.txt) (must be < 10000)"
echo "short lines: $(grep -c '' $SRC/short_description.txt) (must be 1)"
echo "feature lines: $(grep -c '' $SRC/features.txt) (must be 10, each <=200 chars)"
awk '{ if (length($0) > 200) print "TOO LONG ("length($0)"): " $0 }' $SRC/features.txt
echo "search term lines: $(grep -c '' $SRC/search_terms.txt) (must be 7, each <=30 chars)"
awk '{ if (length($0) > 30) print "TOO LONG ("length($0)"): " $0 }' $SRC/search_terms.txt
```
Expected: description bytes well under 10000; short lines `1`; feature lines `10` with no "TOO LONG"; search term lines `7` with no "TOO LONG".

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/windows/store/en-US/
git commit -m "Add Windows Store listing source files (migrated from store-listings.md)"
```

---

### Task 2: Patch + push metadata in the `release-windows` job

Validate the `jq` patch transform against a representative submission fixture (test first), then refactor the single "Publish MSIX to Microsoft Store" step into four gated steps that embed that exact transform, and update the build summary.

**Files:**
- Modify: `.github/workflows/release.yml` — `release-windows` job. Replace the single step at `- name: Publish MSIX to Microsoft Store` (currently ~lines 1374–1401) with four steps; extend the `Build summary` step (~lines 1409–1433). Leave `Check Microsoft Store credentials` (id `ms-store`) and `Set up Microsoft Store Developer CLI` unchanged.
- Test (local, not committed): a fixture JSON in a temp dir to validate the transform.

**Interfaces:**
- Consumes: the four files from Task 1 at `$GITHUB_WORKSPACE/apps/plot/windows/store/en-US/`.
- Produces: a `release-windows` job that, when `steps.ms-store.outputs.enabled == 'true'`, uploads the MSIX as a draft, patches the draft's listing text, and (when `inputs.submit_for_review`) commits the submission.

- [ ] **Step 1: Write the transform test fixture + expected checks**

Create a temp fixture representing what `msstore submission get` returns (includes a leading status line to test stripping, an existing screenshot to prove preservation, and a Free price + title to prove non-target fields survive):

```bash
cd /Users/kris.braun/code/plot
TMP="$(mktemp -d)"
SRC="apps/plot/windows/store/en-US"
printf 'Retrieving existing submission...\n{\n' > "$TMP/raw.txt"
cat >> "$TMP/raw.txt" <<'JSON'
  "id": "1152921500000000000",
  "pricing": { "priceId": "Free" },
  "applicationCategory": "Productivity",
  "listings": {
    "en-us": {
      "baseListing": {
        "description": "OLD DESCRIPTION",
        "shortDescription": "OLD SHORT",
        "features": ["old feature"],
        "keywords": ["old"],
        "title": "Plot",
        "images": [
          { "fileName": "screenshot1.png", "fileStatus": "Done", "imageType": "Screenshot" }
        ]
      }
    }
  }
}
JSON
echo "Fixture written to $TMP/raw.txt"; echo "TMP=$TMP"
```

- [ ] **Step 2: Run the transform and verify it BEFORE touching YAML**

Run the exact extraction + patch pipeline that will go into the workflow, then assert:

```bash
# (reuse $TMP and $SRC from Step 1)
SUB="$(awk '/^{/{f=1} f' "$TMP/raw.txt")"
LANG_KEY="$(printf '%s' "$SUB" | jq -r '
  (.listings // {}) as $l
  | ([$l | keys[] | select(test("^en";"i"))][0]) // ($l | keys[0]) // empty')"
echo "LANG_KEY=$LANG_KEY (expected en-us)"

PATCHED="$(printf '%s' "$SUB" | jq \
  --arg k "$LANG_KEY" \
  --rawfile desc     "$SRC/description.txt" \
  --rawfile short    "$SRC/short_description.txt" \
  --rawfile features "$SRC/features.txt" \
  --rawfile terms    "$SRC/search_terms.txt" '
  .listings[$k].baseListing.description      = ($desc  | rtrimstr("\n"))
  | .listings[$k].baseListing.shortDescription = ($short | rtrimstr("\n"))
  | .listings[$k].baseListing.features         = ($features | split("\n") | map(select(. != "")))
  | .listings[$k].baseListing.keywords         = ($terms    | split("\n") | map(select(. != "")))
')"

printf '%s' "$PATCHED" | jq -e '.listings["en-us"].baseListing.features | length == 10' >/dev/null && echo "OK features=10"
printf '%s' "$PATCHED" | jq -e '.listings["en-us"].baseListing.keywords | length == 7'  >/dev/null && echo "OK keywords=7"
printf '%s' "$PATCHED" | jq -e '.listings["en-us"].baseListing.shortDescription | startswith("Team chat, email")' >/dev/null && echo "OK shortDescription replaced"
printf '%s' "$PATCHED" | jq -e '.listings["en-us"].baseListing.description | test("MADE FOR WINDOWS")' >/dev/null && echo "OK description replaced"
printf '%s' "$PATCHED" | jq -e '.listings["en-us"].baseListing.description | endswith("\n") | not' >/dev/null && echo "OK no trailing newline"
printf '%s' "$PATCHED" | jq -e '.listings["en-us"].baseListing.images | length == 1 and .[0].fileName == "screenshot1.png"' >/dev/null && echo "OK images preserved"
printf '%s' "$PATCHED" | jq -e '.listings["en-us"].baseListing.title == "Plot"' >/dev/null && echo "OK title untouched"
printf '%s' "$PATCHED" | jq -e '.pricing.priceId == "Free"' >/dev/null && echo "OK pricing untouched"
rm -rf "$TMP"
```
Expected output: `LANG_KEY=en-us (expected en-us)` then eight `OK ...` lines, no `jq: error`. If any assertion fails, fix the pipeline here before editing the workflow.

- [ ] **Step 3: Replace the publish step with four steps**

In `.github/workflows/release.yml`, delete the entire existing step that begins with `- name: Publish MSIX to Microsoft Store` (through the end of its `run:` block, i.e. up to but not including `- name: Tag store submission`) and replace it with the following four steps (same indentation, immediately after the `Set up Microsoft Store Developer CLI` step):

```yaml
      - name: Configure Microsoft Store CLI
        if: steps.ms-store.outputs.enabled == 'true'
        shell: bash
        env:
          AZURE_AD_TENANT_ID: ${{ secrets.AZURE_AD_TENANT_ID }}
          SELLER_ID: ${{ secrets.SELLER_ID }}
          AZURE_AD_APPLICATION_CLIENT_ID: ${{ secrets.AZURE_AD_APPLICATION_CLIENT_ID }}
          AZURE_AD_APPLICATION_SECRET: ${{ secrets.AZURE_AD_APPLICATION_SECRET }}
        run: |
          # reconfigure persists credentials to disk for the rest of the job,
          # so the publish/metadata/submit steps below need no re-auth.
          msstore reconfigure \
            --tenantId "$AZURE_AD_TENANT_ID" \
            --sellerId "$SELLER_ID" \
            --clientId "$AZURE_AD_APPLICATION_CLIENT_ID" \
            --clientSecret "$AZURE_AD_APPLICATION_SECRET"

      - name: Publish MSIX to Microsoft Store (draft)
        if: steps.ms-store.outputs.enabled == 'true'
        shell: bash
        run: |
          cd apps/plot/build/windows/x64/runner/Release
          MSIX_FILE="Plot-${{ needs.prepare-release.outputs.release_version }}.msix"

          # Product 9PKTCSN8SNZF = Plot in Partner Center. Always upload as a
          # draft (--noCommit) so the metadata step can patch the same pending
          # submission; the "Submit ... for review" step commits package +
          # metadata together when submit_for_review is set.
          msstore publish "$MSIX_FILE" -id 9PKTCSN8SNZF --noCommit

      # Best-effort: patch the committed Windows listing text onto the pending
      # draft submission. continue-on-error so a locked listing can't fail an
      # otherwise-successful binary release (matches the iOS/Android/macOS
      # metadata steps). updateMetadata is a FULL replace for packaged apps, so
      # we fetch the whole submission and overwrite only the text fields —
      # screenshots and every other field pass through untouched.
      - name: Upload metadata to Microsoft Store
        id: metadata
        if: steps.ms-store.outputs.enabled == 'true'
        continue-on-error: true
        shell: bash
        run: |
          set -euo pipefail
          SRC="$GITHUB_WORKSPACE/apps/plot/windows/store/en-US"

          # Fetch the pending draft as JSON; strip any leading Spectre.Console
          # status line by taking from the first '{' onward.
          RAW="$(msstore submission get 9PKTCSN8SNZF)"
          SUB="$(printf '%s' "$RAW" | awk '/^{/{f=1} f')"
          if [ -z "$SUB" ]; then
            echo "::warning::Could not read submission JSON — skipping metadata."
            exit 0
          fi

          # Pick the English listing key (e.g. en-us); fall back to the first.
          LANG_KEY="$(printf '%s' "$SUB" | jq -r '
            (.listings // {}) as $l
            | ([$l | keys[] | select(test("^en";"i"))][0]) // ($l | keys[0]) // empty')"
          if [ -z "$LANG_KEY" ]; then
            echo "::warning::No listing language on the submission — skipping metadata."
            exit 0
          fi
          echo "Patching listing '$LANG_KEY'"

          PATCHED="$(printf '%s' "$SUB" | jq \
            --arg k "$LANG_KEY" \
            --rawfile desc     "$SRC/description.txt" \
            --rawfile short    "$SRC/short_description.txt" \
            --rawfile features "$SRC/features.txt" \
            --rawfile terms    "$SRC/search_terms.txt" '
            .listings[$k].baseListing.description      = ($desc  | rtrimstr("\n"))
            | .listings[$k].baseListing.shortDescription = ($short | rtrimstr("\n"))
            | .listings[$k].baseListing.features         = ($features | split("\n") | map(select(. != "")))
            | .listings[$k].baseListing.keywords         = ($terms    | split("\n") | map(select(. != "")))
          ')"

          msstore submission updateMetadata 9PKTCSN8SNZF "$PATCHED"
          echo "Metadata pushed for listing '$LANG_KEY'."

      - name: Submit Microsoft Store submission for review
        if: steps.ms-store.outputs.enabled == 'true' && inputs.submit_for_review
        continue-on-error: true
        shell: bash
        run: |
          # Commits the pending submission (package + patched metadata) to
          # certification. Skipped when submit_for_review is false, leaving the
          # draft in Partner Center.
          msstore submission publish 9PKTCSN8SNZF
```

- [ ] **Step 4: Update the `Build summary` step**

In the same job's `- name: Build summary` step, find the `### Microsoft Store` block. Keep the existing disposition lines and add a metadata line directly after them. The block should read:

```bash
            echo "### Microsoft Store"
            if [ "${{ steps.ms-store.outputs.enabled }}" != "true" ]; then
              echo "- ⏭️ Skipped (Store credentials not configured)"
            elif [ "${{ inputs.submit_for_review }}" = "true" ]; then
              echo "- ✅ Uploaded and submitted for certification"
            else
              echo "- 📝 Uploaded as draft — submit it in Partner Center"
            fi
            echo "- Listing metadata: ${{ steps.metadata.outcome == 'success' && 'pushed from apps/plot/windows/store/en-US' || 'not pushed — see the Upload metadata step (skipped if credentials absent)' }}"
```

- [ ] **Step 5: Validate the workflow YAML parses and the steps are present**

Run:
```bash
cd /Users/kris.braun/code/plot
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"
grep -n "name: Configure Microsoft Store CLI" .github/workflows/release.yml
grep -n "name: Publish MSIX to Microsoft Store (draft)" .github/workflows/release.yml
grep -n "name: Upload metadata to Microsoft Store" .github/workflows/release.yml
grep -n "name: Submit Microsoft Store submission for review" .github/workflows/release.yml
grep -c "id: 9PKTCSN8SNZF\|9PKTCSN8SNZF" .github/workflows/release.yml
# The old conditional-commit publish must be gone (no bare publish without --noCommit):
! grep -nE 'msstore publish "\$MSIX_FILE" -id 9PKTCSN8SNZF *$' .github/workflows/release.yml && echo "OK: no bare-commit publish remains"
```
Expected: `YAML OK`; each `grep -n` prints a matching line; the final command prints `OK: no bare-commit publish remains`.

- [ ] **Step 6: Re-run the transform test against the embedded pipeline (regression)**

Re-run Step 1 + Step 2 exactly to confirm the transform still passes after any edits. Expected: `LANG_KEY=en-us` + eight `OK ...` lines.

- [ ] **Step 7: Commit**

```bash
cd /Users/kris.braun/code/plot
git add .github/workflows/release.yml
git commit -m "release(windows): push Store listing metadata via msstore updateMetadata

Split the single MS Store publish step into configure / draft-publish /
updateMetadata / submit-for-review, so listing text from
apps/plot/windows/store/en-US is applied to the same submission as the
package. updateMetadata is full-replace for packaged apps, so fetch-patch-push
preserves screenshots and all non-text fields."
```

---

### Task 3: Documentation

Update the two docs so the source-of-truth move is recorded and discoverable.

**Files:**
- Modify: `docs/store-listings.md` — Microsoft Store section (~lines 362–449).
- Modify: `docs/windows-store-publishing.md` — add a "Listing metadata" section.

**Interfaces:**
- Consumes: file paths created in Task 1; workflow behavior from Task 2.
- Produces: docs only — no code depends on this.

- [ ] **Step 1: Update the Microsoft Store section of `docs/store-listings.md`**

Replace the intro paragraph (the "Windows has no fastlane metadata, so … submitted by hand via Partner Center." text under `## Microsoft Store — Windows`) with:

```markdown
The Windows listing **text** is now pushed by the `release-windows` workflow
from dedicated source files under `apps/plot/windows/store/en-US/` (mirroring the
fastlane convention the other platforms use). Edit the copy in those files; the
blocks below are reproduced for review only. **Screenshots, release notes, and
the product name are still submitted by hand** via Partner Center — the msstore
`updateMetadata` path cannot upload images, and notes/name are out of scope. The
`lint:store-metadata` check does not cover these files.
```

Then add a `**Source:**` citation line under each of the four subsections, matching the iOS/macOS style. Under `### Short description / summary …` add:

```markdown
**Source:** `apps/plot/windows/store/en-US/short_description.txt`
```

Under `### Description — 10,000 char max` add:

```markdown
**Source:** `apps/plot/windows/store/en-US/description.txt`
```

Under `### Product features — up to 20, 200 char max each` add:

```markdown
**Source:** `apps/plot/windows/store/en-US/features.txt` (one feature per line)
```

Under `### Search terms — up to 7, 30 char max each` add:

```markdown
**Source:** `apps/plot/windows/store/en-US/search_terms.txt` (one term per line)
```

(Leave the existing fenced copy blocks in place as the human-readable reference, as the new intro states.)

- [ ] **Step 2: Add a "Listing metadata" section to `docs/windows-store-publishing.md`**

Append this section to the end of the file:

```markdown
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
```

- [ ] **Step 3: Verify the docs**

Run:
```bash
cd /Users/kris.braun/code/plot
grep -n "apps/plot/windows/store/en-US/description.txt" docs/store-listings.md
grep -n "apps/plot/windows/store/en-US/search_terms.txt" docs/store-listings.md
grep -n "## Listing metadata" docs/windows-store-publishing.md
grep -n "cannot upload image bytes" docs/windows-store-publishing.md
```
Expected: each grep prints a matching line.

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot
git add docs/store-listings.md docs/windows-store-publishing.md
git commit -m "docs: Windows Store listing text now sourced from windows/store + pushed by release workflow"
```

---

## Final verification (after all tasks)

- [ ] `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"` → `YAML OK`
- [ ] Task 2 Step 2 transform assertions all print `OK ...`
- [ ] `git log --oneline -4` shows the three task commits (plus the design commit)
- [ ] Manual reminder (cannot be tested in CI): confirm the four GitHub secrets (`AZURE_AD_TENANT_ID`, `AZURE_AD_APPLICATION_CLIENT_ID`, `AZURE_AD_APPLICATION_SECRET`, `SELLER_ID`) are set, and that ≥ 1 screenshot already exists on the Store listing before the first `submit_for_review` run.

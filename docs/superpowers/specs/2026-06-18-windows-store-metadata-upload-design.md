# Windows Store listing-metadata upload via msstore CLI — design

**Date:** 2026-06-18
**Status:** Design (awaiting review)

## Problem

The `release-windows` job in `.github/workflows/release.yml` now auto-uploads the
built MSIX to the Microsoft Store (see
`2026-06-15-windows-store-msstore-publish-design.md`), but it uploads the
**build only**. Listing **metadata** — description, short description, features,
search terms — is still maintained by hand in Partner Center. Every Apple/Google
platform in the same workflow pushes its listing copy + screenshots from
committed sources via `fastlane metadata`; Windows has no equivalent. The
Windows-specific copy currently lives, prose-only, in the Microsoft Store section
of `docs/store-listings.md` and is "submitted by hand via Partner Center."

That prior spec listed "Listing metadata automation (`submission updateMetadata`)"
as explicitly out of scope. **This spec is that follow-up.**

## Goal

Push the Windows Store **listing text** from committed source files as part of
`release-windows`, reaching parity with the other platforms' metadata steps:

- migrate the hand-maintained Windows copy out of `docs/store-listings.md` into
  dedicated per-field source files the workflow can read,
- patch only the text fields onto the live submission, preserving everything else
  (critically, any **screenshots** already uploaded manually in Partner Center),
- keep the existing credential gate and `submit_for_review` semantics,
- remain best-effort (`continue-on-error`) so a locked listing can't fail an
  otherwise-successful binary release — matching iOS/Android/macOS.

## Decisions (from brainstorming)

1. **Tool: same `msstore` CLI.** No fastlane path exists for the Microsoft Store.
   Metadata is pushed with `msstore submission get` → patch → `submission
   updateMetadata` → (conditional) `submission publish`.
2. **Fetch-patch-push, not author-from-scratch — and it is mandatory, not just
   preferred.** Confirmed from the msstore-cli source: for a **Packaged (MSIX)**
   product, `updateMetadata` deserializes the argument into a full
   `DevCenterSubmission` and calls `UpdateSubmissionAsync`, which **replaces** the
   submission. Sending a partial would null out pricing, availability, other
   listing fields, and **images**. So the workflow fetches the current submission,
   patches only the text fields, and sends the whole object back. This is exactly
   why screenshots committed/added elsewhere survive.
3. **Screenshots are deferred — grounded, not hand-waved.** Also from source: the
   image byte-upload (zip → SAS `FileUploadUrl`) lives **only** in the full
   `msstore publish <project>` *project-init* flow (`IStorePackagedAPIExtensions`),
   which this workflow does not use (it publishes the prebuilt MSIX directly).
   `submission updateMetadata`/`update` never upload image bytes. Uploading
   screenshots would mean re-architecting how we publish, so it stays out of scope;
   screenshots remain a manual Partner Center task for now.
4. **Dedicated Windows source files** (the user's choice over reusing the macOS
   copy). The canonical Windows copy migrates from `docs/store-listings.md` into
   `apps/plot/windows/store/en-US/`, one file per field, mirroring the fastlane
   convention. `docs/store-listings.md` keeps the rationale prose and is updated to
   **cite** these files as the source (like the iOS/macOS sections already do).
5. **Always upload the package as a draft; one commit gate at the end.** The
   existing publish step's conditional commit moves to a dedicated final step so
   package + metadata commit **together** in the same submission. See "Ordering".
6. **Fields in scope:** `description`, `shortDescription`, `features[]`,
   `keywords[]` (Store "search terms"). **Out:** `releaseNotes` (per-version, not
   static listing), `title`/product name (reserved name — patching it risks a
   mismatch/rejection), images (decision 3).
7. **Free-product precondition stands.** The CLI errors
   (`App updates are supported only for Free products`) and deletes the submission
   on a paid `PriceId == "Base"`. Plot's listing is free. Recorded as a precondition.

## Source files (new)

Under `apps/plot/windows/store/en-US/`, migrated verbatim from the Microsoft Store
section of `docs/store-listings.md`:

| File | `baseListing` field | Format |
| --- | --- | --- |
| `description.txt` | `description` | free text (≤ 10,000 chars) |
| `short_description.txt` | `shortDescription` | single line (the 94-char site tagline) |
| `features.txt` | `features` | one feature per line (≤ 20 lines, ≤ 200 chars each) |
| `search_terms.txt` | `keywords` | one term per line (≤ 7 lines, ≤ 30 chars each) |

JSON keys are camelCase (`description`, `shortDescription`, `features`,
`keywords`) — System.Text.Json camelCase serialization in the CLI.

## Workflow design (`release-windows`)

The current single **"Publish MSIX to Microsoft Store"** step (reconfigure +
conditional-commit publish) is refactored into four gated steps. All keep the
existing gate `if: steps.ms-store.outputs.enabled == 'true'`, and run in the same
position (after "Create GitHub Release", before "Tag store submission").

### 1. Configure Microsoft Store CLI

`msstore reconfigure --tenantId … --sellerId … --clientId … --clientSecret …`
in its own step. `reconfigure` persists credentials to disk for the rest of the
job, so the later msstore steps need no re-auth. (Secrets stay in `env:`; GitHub
masks them.)

### 2. Publish MSIX (draft)

```bash
msstore publish "$MSIX_FILE" -id 9PKTCSN8SNZF --noCommit
```

**Always** `--noCommit` now (the one behavior change to existing code). The
package lands in a pending draft submission. DevCenter clones the previously
published submission's listing + images into this new draft, so existing
screenshots and copy are present before we patch.

### 3. Upload metadata to Microsoft Store  (`continue-on-error: true`)

```bash
# Capture the current draft submission as JSON (strip any leading status line).
RAW="$(msstore submission get 9PKTCSN8SNZF)"
SUB="$(printf '%s' "$RAW" | awk '/^{/{f=1} f')"

# Pick the English listing key (e.g. "en-us"); fall back to the first listing.
LANG_KEY="$(printf '%s' "$SUB" | jq -r '
  (.listings // {}) as $l
  | ([$l | keys[] | select(test("^en";"i"))][0]) // ($l | keys[0]) // empty')"

if [ -z "$LANG_KEY" ]; then
  echo "::warning::No listing language found on the submission — skipping metadata."
  exit 0
fi

SRC="$GITHUB_WORKSPACE/apps/plot/windows/store/en-US"
PATCHED="$(printf '%s' "$SUB" | jq \
  --arg k "$LANG_KEY" \
  --rawfile desc       "$SRC/description.txt" \
  --rawfile short      "$SRC/short_description.txt" \
  --rawfile features   "$SRC/features.txt" \
  --rawfile terms      "$SRC/search_terms.txt" '
  .listings[$k].baseListing.description      = ($desc  | rtrimstr("\n"))
  | .listings[$k].baseListing.shortDescription = ($short | rtrimstr("\n"))
  | .listings[$k].baseListing.features         = ($features | split("\n") | map(select(. != "")))
  | .listings[$k].baseListing.keywords         = ($terms    | split("\n") | map(select(. != "")))
')"

msstore submission updateMetadata 9PKTCSN8SNZF "$PATCHED"
```

Only the four text fields are overwritten; `images` and all other fields pass
through untouched. `continue-on-error: true` so a temporarily locked listing
can't fail the release. JSON extraction is defensive against a leading
Spectre.Console status line.

### 4. Submit Microsoft Store submission for review  (`continue-on-error: true`)

```yaml
if: steps.ms-store.outputs.enabled == 'true' && inputs.submit_for_review
run: msstore submission publish 9PKTCSN8SNZF
```

Commits the pending submission (package **and** patched metadata) to
certification. When `submit_for_review` is false, the draft is left in Partner
Center — exactly today's behavior, now with metadata applied to the draft.

### 5. Build summary

Add a "Store metadata" line reporting applied / skipped / failed, derived from
the metadata step's `outcome` and `steps.ms-store.outputs.enabled`, alongside the
existing Store disposition line.

## Ordering rationale

`updateMetadata` must run **after** the package draft exists (so it patches the
same pending submission) and **before** any commit. Always-`--noCommit` publish →
patch metadata → conditional `submission publish` guarantees that order and makes
the package + metadata one atomic submission. Splitting reconfigure into its own
step lets all three msstore steps share the persisted credentials.

## Documentation

- **`docs/store-listings.md`** — Microsoft Store section updated: replace the
  inline copy blocks with `**Source:** apps/plot/windows/store/en-US/<file>`
  citations (matching the iOS/macOS sections), and change the "submitted by hand"
  note to "pushed by the `release-windows` workflow; screenshots still manual."
- **`docs/windows-store-publishing.md`** — extend the existing doc with a short
  "Listing metadata" section: where the source files live, which fields are
  pushed, that screenshots/release-notes/title are still manual, and the
  free-product precondition.
- No `docs/updates.md` entry — internal CI/infra change, invisible to users.

## Risks & limitations

1. **Free products only (today).** Same Microsoft limitation as the publish spec;
   the CLI deletes the submission and errors on a paid product. Plot's listing is
   free — confirm before first run.
2. **Full-replace semantics.** Mitigated by fetch-patch-push; the risk is a stale
   fetch (e.g. someone editing the draft in Partner Center concurrently). Accepted.
3. **Pending-draft collisions.** Unchanged from the publish spec — a prior
   uncommitted draft can make a later run error until resolved. With always-
   `--noCommit`, a non-submitted release now *always* leaves a draft, so this is
   slightly more likely; operator resolves via Partner Center or
   `msstore submission delete`. Documented, not auto-handled.
4. **`submission get` output parsing.** Spectre.Console may prepend a status line;
   the `awk '/^{/{f=1} f'` extraction handles a leading non-JSON line. If the CLI
   ever emits trailing non-JSON, revisit. `continue-on-error` contains the blast.
5. **`msstore` is preview.** Action stays pinned (`@v1.2`).

## Out of scope

- **Screenshot / image upload** (decision 3) — requires the project-init publish
  flow; remains a manual Partner Center task.
- **Release notes** (`releaseNotes`) — per-version, not static listing copy.
- **Title / product name** — reserved Store name; not patched.
- Localized listings beyond the single English listing.
- Flighting / staged rollout.

## Files touched

- `.github/workflows/release.yml` — refactor 1 publish step → 4 steps + summary.
- `apps/plot/windows/store/en-US/{description,short_description,features,search_terms}.txt`
  — new source files (migrated copy).
- `docs/store-listings.md` — Microsoft Store section cites the new sources.
- `docs/windows-store-publishing.md` — new "Listing metadata" section.

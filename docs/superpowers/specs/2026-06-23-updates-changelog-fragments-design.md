# Design: fragment-based `docs/updates.md` (no more changelog merge conflicts)

- **Date:** 2026-06-23
- **Status:** Approved (design); implementation plan pending
- **Author:** Kris Braun + Claude

## Problem

When several PRs are open at once, the common workflow is: merge one PR, then
the next PR conflicts — almost always **only** on `docs/updates.md`, because
every PR appends bullets to the same `## Next release` hunk. Resolving the
conflict means editing the file (locally or in GitHub's web editor), pushing,
and **waiting for the full CI suite to re-run** before the second PR can merge.
That wait, multiplied across a stack of PRs, is the pain.

`merge=union` / `git rerere` only help **local** merges — GitHub's merge button,
"Update branch", and web conflict editor ignore `.gitattributes` merge drivers,
so GitHub still flags the conflict and CI still re-runs. The only way to remove
**both** the manual resolution and the CI re-run is to ensure the conflict never
exists: PRs must stop editing the same file.

## Goals

- Two PRs editing the changelog never conflict (no manual resolution, no CI
  re-run).
- Keep it **easy to see what's accumulating** for the next release, at a glance.
- Keep generating the **internal docs page** (`/internal/updates` on the site).
- `docs/updates.md` remains the permanent, append-only, released changelog.
- Minimal change to how a contributor (human or agent) writes an update.

## Non-goals

- No CI gate that *forces* every PR to include a changelog entry (we keep
  today's "skip internal refactors / infra" judgement call).
- No change to the `internal.updates.tsx` route or `internal-docs.server.ts`
  rendering.
- No bot with write access to `main`; no change to where update text is authored
  (it stays in the diff, just in a per-PR file).

## Approach: changelog fragments

Mirror the changeset model already used in `public/`. Each PR drops **one new
file** into a staging directory. Because every PR touches a different file, two
PRs never conflict. At release, the fragments are folded into `docs/updates.md`
and deleted.

### Lifecycle

1. **During a release cycle:** each PR adds one fragment to `docs/updates.d/`.
   They accumulate there. `docs/updates.md` holds **only already-released
   history** — there is no `## Next release` block in it during the cycle, so
   nothing for PRs to conflict on.
2. **At release** (`release.yml` → `stamp-updates.mjs`): gather all fragments →
   assemble one `## <version> — <date>` block (sections grouped, `### Fixes`
   last) → **prepend** it into `docs/updates.md` → **delete** the fragment files.
   Both the new block and the deletions land in the single release commit.
3. **After release:** `docs/updates.d/` is empty again; the next cycle's PRs
   start dropping fresh fragments.

A fragment's whole life: *pending → folded into `updates.md` → deleted* at the
next release.

### The aggregate is never committed mid-cycle

"Easy to see what's accumulating" is served **without** ever committing an
aggregated `## Next release` block (committing that per-PR is the very thing
that conflicts). The live aggregate is computed on the fly from the fragments by
a preview command and by the internal docs page. Only the **release** commit
ever writes an aggregate into `updates.md`.

## Fragment directory & format

- **Directory:** `docs/updates.d/` (a `conf.d`-style staging dir next to
  `updates.md`). Contains a short `README.md` explaining the convention; that
  README is ignored by the gather logic (only fragment files are read — see
  below).
- **Format:** a fragment is exactly what you'd write today — one or more
  `### Section` blocks with bullets:

  ```md
  ### Fixes

  - Links in Plot's update emails now open reliably, instead of spinning forever.
  ```

  A single fragment may carry multiple sections (e.g. a `### Threads` feature
  bullet *and* a `### Fixes` bullet) when a PR spans both.
- **Filename:** `<slug>-<id>.md`, where `<id>` is a short random base36 suffix
  so two PRs that pick the same slug still don't collide. Created by the helper
  (below) or hand-written.
- Fragments are plain markdown, so the existing `lint:md` (markdownlint over
  `docs/**/*.md`) covers them with no config change.
- Section-naming convention is unchanged: descriptive feature sections (e.g.
  `### Threads`, `### Notifications`), with a single `### Fixes` always last.

## Shared gather module: `scripts/lib/updates-fragments.mjs`

One module, three consumers — single source of truth for assembly.

```
gatherFragments(dir) -> { body: string, files: string[] }
```

Algorithm:

1. List `dir`/`*.md`, **excluding `README.md`**, sorted by filename
   (deterministic order). `files` is the absolute paths, returned so the stamp
   step knows what to delete.
2. Parse each file into `(heading, bodyLines)` blocks: a line matching
   `^### (.+)$` starts a section; all subsequent lines (bullets, their wrapped
   continuation lines, and interior blanks) belong to it until the next `### ` or
   EOF. Bullets are **not** split — raw body text is preserved verbatim so
   wrapping/formatting is untouched.
3. Merge bodies across fragments under **identical heading text** (concatenate
   in file-sorted order).
4. Order sections **first-seen**, then force any `Fixes` section to the **end**
   (matches today's convention).
5. Return `body` = the grouped sections (each `### Heading` + its merged
   bullets, separated by blank lines). The **caller** prepends the top-level
   heading (`## Next release` or `## <version> — <date>`).
6. Empty dir → `{ body: "", files: [] }`.

## Consumers

### a) Preview command — `pnpm updates:next`

`scripts/preview-updates.mjs`: prints `## Next release\n\n` + `gatherFragments().body`
to stdout (or a friendly "nothing queued" line when empty). The at-a-glance view
of what's shipping next, runnable locally.

### b) Internal docs page

`apps/site/scripts/sync-internal-docs.mjs` (already reads from `../../../docs`):
when fragments exist, **prepend** a generated `## Next release\n\n` + body block
onto the released `docs/updates.md` content, then write the combined doc to
`apps/site/app/lib/internal-docs/updates.md`. So `/internal/updates` shows
pending (from fragments) **+** released history, always live.

**No changes** to `internal.updates.tsx` or `internal-docs.server.ts`. This
script runs on every site `dev`/`build`, so the deployed page reflects whatever
fragments have merged to `main`.

### c) Release stamp

`scripts/stamp-updates.mjs` is rewritten around the gather module. The pure
function stays testable; signature gains an optional gathered-body parameter so
existing legacy tests keep passing:

```
stampUpdates(updatesContent, version, date, fragmentBody?) -> { stamped, content }
```

- **Fragment path** (`fragmentBody` non-empty): produce
  `## <version> — <date>\n\n<fragmentBody>` and **prepend** it to the top of
  `updatesContent`. `stamped: true`.
- **Legacy fallback** (`fragmentBody` empty): retain today's behavior — rename
  an existing `## Next release` heading in place, else the older
  insert-above-unreleased path. Ensures a smooth transition and back-compat.
- **No-op:** no fragments **and** no legacy unreleased bullets → `stamped: false`,
  content unchanged (same as today).

The CLI wrapper: `gatherFragments()` → call `stampUpdates(...)` → on `stamped`,
write `docs/updates.md` and **`unlinkSync` each gathered fragment file** (so
local runs leave a clean tree too).

`release.yml`: change the staging line from
`git add apps/plot/pubspec.yaml docs/updates.md`
to
`git add apps/plot/pubspec.yaml docs/updates.md docs/updates.d`
so the fragment deletions are recorded in the release commit (`git add` stages
deletions of tracked files within the pathspec).

## Authoring helper — `pnpm updates:new`

`scripts/new-update.mjs "<slug>"`: writes
`docs/updates.d/<slug>-<id>.md` pre-filled with a `### Fixes` template, prints
the path. Used by humans and agents. Hand-authoring a fragment file stays fully
supported and documented.

## CI validation (recommended, lightweight)

`scripts/check-updates-fragments.mjs`: validates that every fragment in
`docs/updates.d/` (excluding `README.md`) parses — at least one `### ` heading
and at least one `- ` bullet, and contains no `## ` (top-level) headings. Folded
into the root `lint` script alongside `lint:store-metadata`. It does **not**
require a PR to contain a fragment.

## One-time migration

Move the current `## Next release` block's three `### Fixes` bullets out of
`docs/updates.md` into a fragment (`docs/updates.d/migrate-pending-<id>.md`),
leaving `docs/updates.md` with released history only. Nothing stranded, no
double-render on the internal page.

## Guidance updates

- `AGENTS.md`: the two `docs/updates.md` authoring bullets (the `/finalize`
  documentation step ~line 498 and the "When completing user-facing changes"
  block ~line 629) → "add a fragment via `pnpm updates:new` or hand-write
  `docs/updates.d/<slug>-<id>.md`", keeping the section-naming + Fixes-last
  conventions and the same "skip internal refactors" guidance.
- `.agents/skills/finalize/SKILL.md` (~line 51): same redirect to the fragment
  workflow.

## Files

**New**

- `docs/updates.d/` — staging dir + `README.md` (convention).
- `docs/updates.d/migrate-pending-<id>.md` — migrated current pending bullets.
- `scripts/lib/updates-fragments.mjs` — `gatherFragments()`.
- `scripts/new-update.mjs` — `pnpm updates:new`.
- `scripts/preview-updates.mjs` — `pnpm updates:next`.
- `scripts/check-updates-fragments.mjs` — fragment validation.

**Modified**

- `scripts/stamp-updates.mjs` (+ `scripts/stamp-updates.test.mjs`).
- `apps/site/scripts/sync-internal-docs.mjs`.
- `.github/workflows/release.yml` (the `git add` line).
- root `package.json` (`updates:new`, `updates:next` scripts; `updates:check`
  wired into `lint`).
- `AGENTS.md`, `.agents/skills/finalize/SKILL.md`.

## Testing

- **`scripts/lib/updates-fragments.test.mjs`** (new): grouping; `Fixes` forced
  last; merge of identical headings across fragments; multi-section fragment;
  `README.md` excluded; deterministic file-sorted order; empty dir →
  `{ body: "", files: [] }`; verbatim preservation of wrapped bullet text.
- **`scripts/stamp-updates.test.mjs`** (extend): fragment path prepends a
  stamped block; no-op when no fragments and no legacy block; legacy fallback
  paths still pass unchanged.
- Manual: `pnpm updates:next` after adding a fragment; `pnpm --filter
  @plotday/site dev` shows pending block on `/internal/updates`; a dry stamp run
  folds fragments and removes the files.

## Risks / edge cases

- **Two PRs, same filename** — prevented by the random `<id>` suffix; if a human
  hand-writes a colliding name, git surfaces it as an add/add conflict on that
  one file (rare, and obvious).
- **Malformed fragment** — caught by `check-updates-fragments.mjs` in CI before
  it can reach a release.
- **Transition window** — until the migration lands, a stray `## Next release`
  block could exist in `updates.md`; the legacy fallback in `stampUpdates`
  handles it, and the migration removes it in the same change.
- **markdownlint** — fragments live under `docs/**`, already covered by
  `lint:md`; no rule changes expected (they're ordinary `### ` + bullet
  markdown).

## Open questions

None outstanding. Directory name (`docs/updates.d/`) and the `<slug>-<id>`
filename scheme are defaults chosen in design; trivially adjustable during
implementation if preferred.

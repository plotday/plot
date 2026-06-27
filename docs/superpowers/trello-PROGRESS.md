# Trello Connector — Build Progress / Resume Guide

**Branch:** `trello-connector` (worktree `/Users/kris.braun/code/plot/.claude/worktrees/trello-connector`)
**Submodule `public`:** gitlink → `e00516f` (latest public main: Plans 1–3 twister/connector + Plan-4 checklist sync #239 + calendar fix #238)
**Last main-repo commit:** `chore(public): re-point gitlink to e00516f` (2026-06-27) — **re-rebased onto `origin/main` (`48b6bbd87`, #493)**; Plans 1–4 + gitlink at `e00516f`. core#481 now **MERGEABLE, all gates green** (see rollout below).
**Worktree DB:** port in `.worktree-db` (`54330`). ⚠️ Session `$DATABASE_URL` goes stale (points at main `54322`) — override it from `.worktree-db` on every migration command.

> Detailed per-task log (controller ledger, gitignored): `.superpowers/sdd/progress.md` in this worktree.

## Status

| Plan | What | Status |
|---|---|---|
| **Spec** | `docs/superpowers/specs/2026-06-25-trello-connector-design.md` (v2, Part 3 = structured-items) | ✅ approved, committed |
| **Plan 1** | Trello **auth provider** (`AuthProvider.Trello` token-fragment flow): `docs/superpowers/plans/2026-06-25-trello-auth-provider.md` | ✅ complete & merge-ready (7 tasks, final opus review passed; XSS HIGH caught+fixed) |
| **Plan 2** | Trello **connector core**: `docs/superpowers/plans/2026-06-25-trello-connector-core.md` | ✅ complete & merge-ready (11 tasks, final opus review passed; dead archive-branch + post-auth-cred bugs caught+fixed) |
| **Plan 3** | **structured-items foundation** (server/SDK): `docs/superpowers/plans/2026-06-25-trello-structured-items-foundation.md` | ✅ complete & merge-ready (Tasks 1–5; final opus whole-branch review passed after 2 Important fixes) |
| **Plan 4** | Trello **checklist sync** (checkItem→note, two-way completion/assignment): `docs/superpowers/plans/2026-06-26-trello-checklist-sync.md` | ✅ complete (6 tasks, all reviews Approved; submodule branch `trello-checklist-sync` commits `db530e1..59320e1`; final whole-branch review pending) |
| **Plan 5** | **client UI** (Drift `note` columns + grouped/ordered checklist rendering + capability gating) | ⬜ not started — plan file not yet written. ⚠️ **MUST `seq`-bump `note`** when the Drift columns land (carried Plan-3 prerequisite — see §"Plan 5 prerequisite" below) |

## What Plan 3 delivered (complete)

Server/SDK foundation so checklist items can sync as Plot **notes** with two-way completion + assignment, end-to-end:
- **DB:** `note.section_key/section_label/section_position/item_position` (nullable `text`), exposed in `user.note`/`user.note_redacted` (Task 1) and the 3 note-dispatch views `twist_instance_note_create`/`_update`/`twist_instance_channel_note_create` (Task 3) — additive `CREATE OR REPLACE VIEW` migrations.
- **SDK** (`public/twister`, Task 2): `Note.sectionKey/sectionLabel/sectionPosition/itemPosition` (`string|null`, required), `Note.tagActors: Record<ActorId, Actor>` (excluded from `NewNote`), `Actor.source?:{accountId}|null`, + changeset.
- **Runtime** (`workers/api`, Tasks 3+4): `createNote` persists the cols (insert + keyed-upsert, incl. the `onConflictWhere` fix so reorder/move-only re-syncs persist); all dispatched/read Note builders propagate them; `dispatch()` enriches `note.tagActors` + `note.author.source` from `contact_external_account` scoped to `this.twistInstanceId` in one batched query (no per-actor lookup) on all three note emitters.

Ledger: `.superpowers/sdd/progress.md` (gitignored) has the full per-task log incl. review/fix cycles.

## ⚠️ Plan 5 prerequisite (carried from the Plan 3 final review)

The Plan 3 view-column migrations did **NOT** one-shot bump `note.seq`. This is intentional (the client doesn't read the new columns until Plan 5; bumping now would force a pointless mass re-sync). **When Plan 5 adds the Drift columns, it MUST include a `seq` bump / backfill** (per `libs/db/AGENTS.md` "bump on schema changes that add view columns") so existing notes re-sync with their section data.

**Second Plan 5 prerequisite (from the Plan 4 final review) — sort positions NUMERICALLY.** Plan 4's connector stores `section_position`/`item_position` as `text` via `String(checklist.pos)` / `String(item.pos)`. Trello's `pos` increments by 16384, so a checklist with 6+ items crosses from 5- to 6-digit values and **mis-sorts under a lexicographic `ORDER BY`** (e.g. `"98304" > "114688"` because `'9' > '1'`, but `98304 < 114688`). The emitted data is recoverable (every value parses as a float). **Plan 5 MUST sort `item_position` / `section_position` numerically (`::numeric`)** when it renders grouped/ordered checklist items — or re-encode at the producer. The "fractional index" label in the spec/JSDoc is misleading for plain `String(pos)`; treat these as plain numeric-as-text.

## Plan 4 — DONE (Trello checklist sync, Layer 2)

Plan: `docs/superpowers/plans/2026-06-26-trello-checklist-sync.md`. Connector-only (`public/` submodule). Built via `superpowers:subagent-driven-development` (6 TDD tasks, every task review Approved). **Submodule branch `trello-checklist-sync`** (off merged `4c4d0527`), commits `db530e1..59320e1`:

- **Sync-in:** `getCards`/`getCard` fetch `checklists=all&checkItems=all` (incl. `idMember`); `transformCard` emits one `checkitem-{id}` note per item with `section_key`=checklist id / `section_label`=name / `section_position`=`String(checklist.pos)` / `item_position`=`String(item.pos)`, inbound `Tag.Todo` from `idMember` and item-level `Tag.Done` collapse (assignee, else connection owner via cached `GET /members/me`).
- **Write-back** (`onNoteUpdated` `checkitem-*`): full-note reconcile → `PUT /cards/{id}/checkItem/{id}` — any `Done`⇒`complete` / none⇒`incomplete`; first `Tag.Todo` actor → `idMember` via `note.tagActors[id].source.accountId` (Plan-3 enrichment), unresolvable assignee → non-blocking `deliveryError`; `name`=content.
- **Deletion** (webhook-action driven): `deleteCheckItem` / `removeChecklistFromCard` archive the affected `checkitem-*` notes via `saveNote(archived:true)`, resolved from a persisted per-card `checklist_items_{cardId}` map. (Tradeoff: deletions during webhook downtime aren't caught up.)

48 connector tests green; `plot lint` + `tsc` clean. **Deferred to v-next (per spec §3.7):** create/delete a checkItem *from Plot* (`onNoteCreated` for `checkitem-*`); Layer-3 app UI = **Plan 5**.

## What works now (Plans 1+2+4)

Connect Trello → boards become channels with per-board list-statuses → cards sync in (description, comments, members→contacts, attachments, **checklist items**) → real-time webhook updates (HMAC-verified) → write back card moves, comments, new cards, **and checklist completion/assignment/rename/deletion**. 48 connector tests + ~18 auth-runtime tests, all green; tsc/lint/build clean.

## Deferred follow-ups (none block the connector)

- **Archive-a-card-from-Plot write-back** — removed as dead code; needs a runtime change (add `archived` to `Link`/`fromDbLink` + changeset). Inbound archive + done-list status work.
- **Verify >100-card board pagination** (`before`-cursor id ordering) on a real large board during provisioning.
- Minor hygiene: timing-safe HMAC compare, `encodeURIComponent` the `before` cursor, a few test-coverage gaps, `deliveryError`+retry for note write-back.
- **(Plan 4) `convertToCardFromCheckItem` orphans the checkItem note** — converting a Trello checkItem into a card is neither `deleteCheckItem` nor `removeChecklistFromCard`, so `onWebhook` falls through to the card re-fetch (`saveLink` doesn't reconcile-delete absent notes); the old `checkitem-{id}` note lingers while the new card also appears as its own thread (visible duplicate). Consistent with the accepted v1 "deletions aren't fully reconciled" tradeoff. Fix when prioritized: add `convertToCardFromCheckItem` to the deletion-archival branch in `onWebhook`, treating it like `deleteCheckItem`.
- **(Plan 4) checklist-item create/delete *from Plot*** — `onNoteCreated` for a `checkitem-*`-shaped note (deferred per spec §3.7); no app UI yet.
- **(Plan 4) test-coverage Minors** (all follow-up, none block): `getCard` query asserts 2/4 params; `me()` GET-method + empty-`fields` `updateCheckItem` untested; assigned-incomplete (Todo-only) transform case; `note.tags===undefined` write-back case; absent-IDs no-op deletion cases. Hygiene: `removeChecklistFromCard` does an unconditional `this.set` when `checklistId` is absent (wasted write); `fire()` test helper's unused `store` param; duplicated `sign()` test helper.

## Merge rollout — state & remaining steps

**Two-PR rollout** (`public/` submodule merges first; then `core` bumps the gitlink). The core PR's API runtime depends on the new twister types, so core CI cannot pass until the submodule PR merges and the gitlink is re-pointed.

1. ✅ **Submodule PR OPEN & GREEN — [plotday/plot#236](https://github.com/plotday/plot/pull/236)** (`trello-connector` → `main`, submodule HEAD `ce38184`). Mergeable, mergeState CLEAN, the Changeset Check passes. Contains: `AuthProvider.Trello`, structured-item twister types + 2 changesets, and the full `connectors/trello` package. (CI initially failed `frozen-lockfile`: the connector scaffold updated the core repo's root lockfile but not the standalone `public/pnpm-lock.yaml` — fixed in commit `ce38184`.) Ready for human review/merge.
2. ✅ **Submodule #236 MERGED** → plot/main `4c4d0527`. **Core PR OPEN (DRAFT) — [plotday/core#481](https://github.com/plotday/core/pull/481)** (`trello-connector` → `main`; gitlink bumped to `4c4d0527`, core root `pnpm-lock` regenerated, `frozen-lockfile` + workers/api tsc verified clean against the merged submodule).
   - ✅ **REBASED onto `origin/main` (2026-06-26)** and **force-pushed** (tip now `856981b88`, incl. Plan-4 docs; `--force-with-lease` from `4e1cbc735`). core#481 now shows the rebased history. Rebase base `39a78fa2f` (`#484`); the original design-spec commit `92f280be1` was auto-dropped (main carries it via #461). The **gitlink bump is still deferred** — core#481 carries Plan-4 docs but NOT the Plan-4 submodule HEAD; re-point after plot#239 merges. Conflicts resolved at rebase time:
     - **`public` gitlink** → ours `4c4d0527` — verified a strict **descendant** of main's `6f7acd10` (Trello submodule merge was built on top of main's submodule HEAD), so it loses nothing.
     - **`libs/db/migrations/atlas.sum`** → regenerated with `atlas migrate hash` (all 4 migrations: main's `…212745`/`…213000` + ours `…225845`/`…234247`). Migration files themselves did NOT conflict (distinct timestamps).
     - **`libs/db/schema/50-tables/25-note.sql`** → auto-merged, kept BOTH (main's `activity_*` trigger refs + our `section_*`/`item_position` columns).
     - **`workers/api/.../integrations.ts`** → manual: both added a new top-level fn at the same spot (main's `boundConnectionsWithoutToken` + our `withTrelloAppCreds`) → kept both. `plot/link.ts`, `plot/thread.ts` auto-merged (distinct regions).
     - **`docs/.../2026-06-25-trello-connector-design.md`** → ours (main carries the stale **v1**; ours is v2). **`pnpm-lock.yaml`** / **`types.ts`** auto-merged.
   - **Post-rebase gates ALL GREEN:** `diff-schema-migrations` in-sync · `db:lint` types up-to-date · `pnpm install --frozen-lockfile` clean · workers/api `tsc` + `eslint` clean · `twist/tools` + Trello suites 270/271 (the 1 fail = a worktree-DB parallelism **deadlock** in `integrations-savenotes.test.ts` setup — passes 3/3 in isolation, not a regression).
   - ⚠️ **Worktree DB NOT reconciled** (no permission to reset): it has ours `…225845`/`…234247` applied but is MISSING main's `…212745`/`…213000` (they sort earlier → out-of-order). Harmless for verification — main's two are trigger/data-only (no column changes), so type-gen is unaffected; the gates above are DB-state-independent (Atlas dev DB) or use the already-correct column set. Apply main's two (or reset+reapply) before any NEW migration work in this worktree.
   - Core PR contents: auth-provider runtime (Plan 1), connector runtime fix + `connections.ts` availability flip (Plan 2), structured-items DB migrations + runtime (Plan 3), gitlink bump.
3. ✅ **Plan 4 submodule #239 MERGED** → public/main `e00516f` (merge of `trello-checklist-sync`). ✅ **Core gitlink re-pointed to `e00516f`** on the rebased core#481 (commit `chore(public): re-point gitlink to e00516f`). **core#481 re-rebased onto `origin/main` (`48b6bbd87`, #493, 2026-06-27)** — only `atlas.sum` needed manual resolution (×2, regenerated via `atlas migrate hash`); `types.ts`/`integrations.ts`/`features.md`/`pnpm-lock`/schema views all auto-merged cleanly. **Gates ALL GREEN:** `diff-schema-migrations` in-sync · `db:lint` types up-to-date · `pnpm install --frozen-lockfile` clean · workers/api `tsc && eslint` exit 0 · apps/site `tsc && eslint` exit 0 · unit 1014 pass (the 3 `plot/link*.test.ts` fails are the known worktree-DB parallelism deadlock — 6/6 pass in isolation) · integration 195 pass/1 skip. The standalone "Update public" PR **core#494 is now redundant** (its bump is folded into core#481) — close it.
4. ⚠️ **Provisioning (OPS, human-gated) — blocks DEPLOY of the core change:** Trello app key+secret → 1Password (`AUTH_TRELLO_ID`/`AUTH_TRELLO_SECRET`) → root `.env`/`.env.production` `op://` refs → `bash scripts/sync-github-secrets`. The core PR flips Trello to **available** in `connections.ts`; if it deploys before provisioning, the prod connect button 500s. Provision before (or simultaneously with) the core merge/deploy.

- **Stray commit (unrelated):** a duplicate spec commit sits on the concurrent `promote-google-outlook` branch (local-only) — drop it (`git reset --hard origin/promote-google-outlook`) before that branch is pushed.

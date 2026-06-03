# Two-step thread creation — implementation plan (OVERVIEW / ROADMAP)

> **For agentic workers:** This is the **roadmap**, not a task list. Each phase below has (or will have) its own detailed, checkbox-tracked plan file in this directory. Execute phases in dependency order. Per phase, use **superpowers:subagent-driven-development** (recommended) or **superpowers:executing-plans**.

**Spec:** `docs/superpowers/specs/2026-06-02-two-step-thread-creation-design.md`
**Branch:** `feat/two-step-thread-creation`

**Goal:** Turn thread creation into a two-step flow (pick a *target* → compose), drive the target list from a global MRU + search, and move team scoping from focuses onto threads with a membership gate that exempts non-team (customer) contacts.

**Architecture:** Mostly a *refactor* of existing systems — a priority-keyed team firewall becomes thread-keyed; the existing `LocalPreferencesBloc` connection-MRU is widened into a target list; the existing compose field-row widgets are re-staged into two steps. New build is limited to the `external_contacts` exemption, the `"none"` sharing model, and the target-list synthesis/search.

**Tech stack:** Postgres (Atlas migrations), `@plotday/twister` (TS SDK), Cloudflare Workers (TS), Flutter/Dart (Drift, Bloc, forui).

---

## Key architecture notes — READ BEFORE EXECUTING

These were verified against the tree during planning and **override** any stale guidance:

1. **The team firewall already exists, priority-keyed.** `user.thread` (`libs/db/schema/90-user-schema/30-thread.sql:215-225`) already gates visibility:
   ```sql
   AND ( p.team_id IS NULL
         OR EXISTS (SELECT 1 FROM public.team_user tu2
                    WHERE tu2.team_id = p.team_id AND tu2.user_id = tp.user_id
                      AND tu2.archived_at IS NULL) )
   ```
   where `p` is the per-user *filed priority*. Phase 2 **rekeys** this to the thread's own `a.team_id`, adds the `external_contacts` exemption, and drops the `JOIN priority p` (it exists only for this check).

2. **Sync is seq-cursor based; there is NO notify function / Zod thread schema.** `rg` finds no `notify_internal_api_for_activity` or `ActivityItemSchema`. The `libs/db/AGENTS.md` "notify + Zod" section is stale for `thread`. To surface `team_id` to clients, add it to the `user.thread` SELECT. `external_contacts` is server-only (firewall input).

3. **`user.upsert_thread` is the single write path** for both user- and connector-created threads (`libs/db/schema/90-user-schema/80-upsert_thread.sql`). It's where `thread.team_id` is written (immutable on update; default from the creating `twist_instance.team_id` for connector threads). The client payload→`p_thread` mapping lives in `85-user-sync-upserts.sql`.

4. **Filing triggers stay unchanged.** `file_thread_priority_peers` / `file_thread_priority_for_group_members` over-file (they file all peers/group members pending); the view firewall hides non-members and team-leave revokes them. No team logic needed in filing.

5. **Flutter sharing enum is `ln` in `apps/plot/lib/store/link.dart`**, resolved by `Thread.resolveln(links)` (`store/thread.dart`) and switched on in `note_editor.dart`, `widget/thread.dart`, `widget/note.dart`, `page/new_thread.dart`. `none` is added here in the Flutter phase.

6. **MRU infrastructure already exists** in `apps/plot/lib/state/local_preferences.dart`: `connectionMru` (per-key, global + per-priority timestamps), `recordConnectionUsage`, `rankConnectionsByMru`, `lastUsedConnectionKey`. Phase 4 widens the key/signature (contacts/groups + team), adds a global rank, materializes a cached list, and adds search synthesis.

7. **Focuses are flat and team-leave is being decoupled from focus archival** by the in-flight **merge-focus** change (`docs/superpowers/plans/2026-06-02-merge-focus.md`). Phases 2/6 must land *with/after* it: do not reintroduce leave-team-on-archive; team-leave revocation moves onto `thread.team_id`.

---

## Phases (expand → switch → contract)

| # | Phase | Layer | Depends on | Plan file |
|---|---|---|---|---|
| 1 | Twister `"none"` sharing model | TS SDK + connector | — | `…-phase1-twister-sharing-none.md` ✅ |
| 2 | DB team scoping: add columns, rekey firewall, classification + revocation triggers, backfill (**expand**) | Postgres | 1 (none value referenced by connectors only) | `…-phase2-db-team-scoping.md` (next) |
| 3 | Flutter store/types: Drift `teamId`/(no `externalContacts` needed client-side), carry team through compose/finalize, stop reading `priority.team_id`/defaults, add `ln.none` | Flutter | 2 | `…-phase3-flutter-store-types.md` |
| 4 | MRU substrate: widen `connectionMru` signature, global rank, materialized cache + incremental update, correspondent/email search | Flutter (bloc) | 3 | `…-phase4-mru-substrate.md` |
| 5 | Compose UI: two-step machine, extract `TargetPickerList`, reorder (Connection→Focus→Contacts), auto-focus, focus auto-suggest (no Auto-organize), drop Task, Note/Chat rename, hide contacts for no-roster | Flutter (UI) | 3, 4, 1 | `…-phase5-compose-ui.md` |
| 6 | DB contract: drop `priority.team_id` + `default_*`; remove `priority_team` triggers + `team_user_ensure_team_priority`; rename/repoint leave-revocation | Postgres | 3 (clients stopped reading) + merge-focus | `…-phase6-db-contract.md` |

**Ordering rationale:** add new columns and rekey the firewall *before* clients switch (Phase 2), have Flutter read/write the new shape (Phase 3) and stop reading the soon-dropped columns, then drop the old columns last (Phase 6) — classic expand/contract so a deployed old client/worker never reads a dropped column. Phases 4 and 5 are client-only and can overlap once Phase 3 lands. Phase 1 is independent and can land first.

## File structure (map; authoritative file lists live in each phase plan)

- **Phase 1:** `public/twister/src/tools/integrations.ts` (union), `public/.changeset/<name>.md`, `public/connectors/google-tasks/src/google-tasks.ts`.
- **Phase 2:** `libs/db/schema/50-tables/24-thread.sql` (+columns); `90-user-schema/30-thread.sql` (rekey firewall, expose `team_id`, drop `JOIN priority p`); new `90-user-schema/06b-user_team_ids.sql`; new `95-triggers/29-thread_team_classify.sql` (external classification + connector default); `95-triggers/27-team_user_lifecycle.sql` (repoint revocation to `thread.team_id`, add re-join un-revoke, remove team-focus creation); `80-upsert_thread.sql` + `85-user-sync-upserts.sql` (carry `team_id`); migration + backfill; `libs/db/src/types.ts` (regen).
- **Phase 3:** `apps/plot/lib/store/thread.dart` (Drift `teamId`, factory/`finalizeThreadDraft`, drop `inheritedDefaultShared*` seeding), `store/priority.dart` (stop exposing defaults/team), `store/link.dart` (`ln.none`), Drift schema-version bump + migration.
- **Phase 4:** `apps/plot/lib/state/local_preferences.dart`, `widget/connection_targets.dart`, `store/actor.dart`, `store/channel.dart`.
- **Phase 5:** `apps/plot/lib/page/new_thread.dart`, new `widget/compose/target_picker_list.dart`, `widget/compose/connection_choice.dart`, `widget/select_modal.dart` (extract content), `command/thread.dart` (NewThread reset).
- **Phase 6:** `libs/db/schema/50-tables/22-priority.sql`, `95-triggers/26-priority_team.sql` (remove), `27-team_user_lifecycle.sql`, migration.

## Execution

Write each phase plan just-in-time (read the phase's target files first for accurate code), execute it (subagent-driven or inline), verify, then proceed. Commit per task on `feat/two-step-thread-creation`. Coordinate Phase 2/6 with the merge-focus branch before dropping priority columns.

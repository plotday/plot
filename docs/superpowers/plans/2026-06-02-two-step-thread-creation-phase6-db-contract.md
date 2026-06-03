# Phase 6 — DB/Drift contract cleanup — Implementation Plan

> **For agentic workers:** Implementer brief, two sub-tasks (6a DB → 6b Flutter). This is the **contract** half of expand/contract: drop the now-unused per-focus team/default-contacts machinery. Clients already stopped reading it (Phase 2 rekeyed the firewall off `priority.team_id`; Phase 5 removed the defaults UI/seeding), so the drop is safe. Steps use `- [ ]`.

**Goal:** Remove `priority.team_id` + `priority.default_contacts/default_groups/default_invite_emails` (and all their machinery) from the DB and the Flutter store. After this, focuses are purely organizational and team-agnostic; team scope lives only on `thread.team_id`.

**⚠️ Coordinate with the in-flight merge-focus branch.** merge-focus already removed the app-side "leave team via focus archive" path. This phase removes the DB-side team-focus lifecycle (`team_user_ensure_team_priority`, the priority-archive branch of `team_user_archive_priorities`, the `priority_team_*` triggers). If merge-focus has touched `27-team_user_lifecycle.sql`, reconcile rather than clobber. On THIS branch, implement the full removal per the spec.

**Production-safety note:** dropping columns is a contract step that must deploy AFTER the Phase 3/5 clients that stopped reading them. For local worktree execution just apply the migration; the rollout ordering is a release concern.

**Working directory:** `/Users/kris.braun/code/plot/.claude/worktrees/two-step-thread-creation` (branch `two-step-thread-creation`). Confirm `pwd && git branch --show-current`.

---

## ⚠️ DATABASE SAFETY (6a) — same hazard as Phase 2

The worktree Postgres is on **port 54336**; this session's ambient `$DATABASE_URL` is STALE (main repo's 54322). For EVERY DB command set it inline: `DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54336/postgres" pnpm apply-migrations` (and `gen-migration`, `diff-schema-migrations`, `psql`). Sanity-check with `psql "$DATABASE_URL" -tAc "show port;"` → must print **54336**. Never run a migration against 54322.

---

## Sub-task 6a — DB: drop priority team/defaults + their machinery

**First, find every reference** (a column drop fails if a view/function still selects it):
```bash
rg -n "\bteam_id\b|default_contacts|default_groups|default_invite_emails" libs/db/schema | rg -i "priority|priority_team|team_user_ensure|inherit" 
rg -rn "p\.team_id|priority.*team_id|default_contacts|default_groups|default_invite_emails" libs/db/schema
```
Resolve ALL references before dropping. Known sites:

- [ ] **`libs/db/schema/50-tables/22-priority.sql`** — drop columns `team_id`, `default_contacts`, `default_groups`, `default_invite_emails`, and the `idx_priority_team_id` index. Keep everything else.
- [ ] **`libs/db/schema/95-triggers/26-priority_team.sql`** — remove the file's contents (the `priority_team_inherit` / `priority_team_lock` / `priority_team_cascade` functions + triggers) entirely. (If the build requires the file to exist, leave it empty with a comment; otherwise delete it — match how the schema dir treats removed files; check `pnpm diff-schema-migrations` after.)
- [ ] **`libs/db/schema/95-triggers/27-team_user_lifecycle.sql`** — remove `team_user_ensure_team_priority` (function + trigger). In `team_user_archive_priorities`, remove the second `UPDATE public.priority SET archived_at …` branch (no more team focuses to archive); keep ONLY the thread-revocation `UPDATE thread_priority … FROM thread t WHERE t.team_id = NEW.team_id …` (added in Phase 2). Consider renaming the function to `team_user_revoke_team_threads` for clarity (update the trigger name too). KEEP `team_user_block_last_admin` and `team_user_unrevoke_team_threads` (Phase 2) untouched.
- [ ] **The `user.priority` view** — find it (`rg -ln '"user"\."?priority"?' libs/db/schema/90-user-schema` / search for `CREATE OR REPLACE VIEW "user".priority`). Drop `team_id` and `default_contacts/groups/invite_emails` from its SELECT and from the view's row shape.
- [ ] **`libs/db/schema/90-user-schema/85-user-sync-upserts.sql`** — in `upsert_priority`, remove `default_contacts/default_groups/default_invite_emails` from the INSERT column list + VALUES + the `ON CONFLICT DO UPDATE SET`, and remove any `team_id` handling. The `jsonb_populate_record(NULL::"user"."priority", …)` will no longer have those fields once the view drops them — ensure no leftover references.
- [ ] **Any other references** the grep surfaced (e.g. `classify_thread_for_user`, other views/functions reading `priority.team_id` or the defaults) — update/remove so nothing references the dropped columns.
- [ ] **Generate + apply** (54336 URL): `DATABASE_URL=…54336 pnpm gen-migration -- drop_priority_team_and_defaults`. **Inspect** the generated migration — it should drop the columns/index, drop/replace the triggers/functions, and DROP/RECREATE the dependent `user.priority` view; flag anything out of scope. Then `DATABASE_URL=…54336 pnpm apply-migrations` (auto-runs types). `DATABASE_URL=…54336 pnpm diff-schema-migrations` → no diff. Commit the regenerated `libs/db/src/types.ts`.
- [ ] **Verify**: `psql "$DATABASE_URL" -tAc "select column_name from information_schema.columns where table_schema='public' and table_name='priority' and column_name in ('team_id','default_contacts','default_groups','default_invite_emails');"` → returns **nothing**. `team_user_ensure_team_priority` gone: `psql "$DATABASE_URL" -tAc "select proname from pg_proc where proname='team_user_ensure_team_priority';"` → empty. `pnpm --filter @plotday/db run lint` → types up to date.
- [ ] **Commit:** `feat(db): drop priority.team_id + per-focus default-contacts (contract)`.

---

## Sub-task 6b — Flutter: drop priority team/defaults columns + references

- [ ] **`apps/plot/lib/store/priority.dart`** — remove the Drift columns `teamId`, `defaultContacts`, `defaultGroups`, `defaultInviteEmails`; the `inheritedDefaultSharedContacts/Groups/InviteEmails` getters; the `fromBase` parsing of those fields; and their forwarding in the `Priority` constructor / `fromStore` / `copyWith`. (Recall the fromStore-drops-columns pattern — remove from ALL forwarding sites.)
- [ ] **`apps/plot/lib/store/store.dart`** — bump `schemaVersion` to the next number; add an `onUpgrade` step dropping the columns. Per `apps/plot/AGENTS.md`, drop columns via `await m.alterTable(TableMigration(priorities));` (Drift rebuilds the table keeping only current columns) at the new version.
- [ ] **`apps/plot/lib/command/priority.dart`** — `EditPriorityCommand` (and `CreateNewPriority`/`NewFocus` if present) must stop passing `teamId` / the default-* fields to `Priority(...)`/`copyWith` (5c already removed the default-* UI; this removes the residual `teamId` plumbing). 
- [ ] **Grep for stragglers:** `rg -n "teamId|defaultContacts|defaultGroups|defaultInviteEmails|inheritedDefaultShared" apps/plot/lib` — remove/adjust any remaining references (none should remain that read these on `Priority`). Do NOT touch `thread.teamId` or `twist_instance.teamId` — those stay.
- [ ] **Codegen + verify:** `cd apps/plot && flutter pub get && flutter pub run build_runner build --delete-conflicting-outputs`; `flutter analyze` clean on changed files; run `flutter test test/state/compose_targets_test.dart` (and any priority store tests) to confirm no regression.
- [ ] **Commit:** `feat(app): drop priority team/default-contacts columns (contract)`.

---

## Acceptance
- `priority` table + `user.priority` view have no `team_id`/`default_*`; `priority_team_*` triggers and `team_user_ensure_team_priority` are gone; `team_user_archive_priorities` only revokes threads by `thread.team_id`; `diff-schema-migrations` clean; `types.ts` regenerated.
- Flutter `Priority` has no `teamId`/`default*` columns or `inheritedDefaultShared*` getters; Drift migration drops them; `EditPriorityCommand` no longer references them; `flutter analyze` clean; tests green.
- `thread.team_id` (the actual team scope) and `twist_instance.team_id` are untouched. The two-step compose flow (Phases 1–5) still builds.

## Out of scope
No changes to `thread.team_id`, the firewall, the compose UI, or the MRU substrate — those are done. This phase only removes the obsolete per-focus team/defaults.

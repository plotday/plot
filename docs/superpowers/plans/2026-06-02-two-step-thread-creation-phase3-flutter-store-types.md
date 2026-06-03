# Phase 3 — Flutter store/types (additive) — Implementation Plan

> **For agentic workers:** This is an implementer brief — the exact integration points live in large Flutter files you must read; the requirements, contract, acceptance criteria, and gotchas below are precise. Follow `apps/plot/AGENTS.md` for Drift migrations and code style. Steps use `- [ ]`.

**Goal:** Make the Flutter client carry a thread's team scope (`thread.teamId`) end-to-end (sync pull + push, model, draft finalize) and recognize the new `ln.none` sharing model. **Purely additive and non-breaking** — it does NOT change the compose UI (Phase 5) and does NOT remove the priority default-contacts feature (UI removal is Phase 5; DB/Drift column removal is Phase 6). After this phase, a thread round-trips `team_id` through sync, defaulting to `null` (Personal) since nothing sets it yet.

**Architecture:** Mirror the server contract from Phase 2 (already merged on this branch): `thread.team_id bigint NULL` exists in Postgres, `user.thread` exposes it, and `workers/api/src/app/sync/threads.ts` already maps `teamId`↔`team_id` into `upsert_thread`. This phase adds the client side of that round-trip plus the `ln` enum value.

**Tech Stack:** Flutter/Dart, Drift (SQLite), Bloc. Imports: only `flutter/widgets.dart` and `forui/forui.dart` (never `flutter/material.dart`).

**Working directory:** `/Users/kris.braun/code/plot/.claude/worktrees/two-step-thread-creation` (branch `two-step-thread-creation`). Confirm with `pwd && git branch --show-current` first.

---

## Context you need (read these before coding)

- `apps/plot/lib/store/link.dart` — the `ln` enum (the Flutter mirror of Twister's `sharingModel`) and `ln.fromJson` (maps `'channel'`/`'message'` → variants, default `ln.thread`). Phase 1 added `"none"` to the Twister union.
- `apps/plot/lib/store/thread.dart` — `Thread` model, the Drift `ThreadRow`/threads table, `Thread.resolveln(links)`, the `Thread(...)` factory, `finalizeThreadDraft(...)`, and `_fromStore(...)`. This is where `teamId` is added.
- `apps/plot/lib/store/store.dart` — `Store.schemaVersion` and `Store.migration.onUpgrade` (Drift incremental migrations).
- The thread **sync** code: where the client parses `/sync/threads` rows into the local table and where it serializes local threads to push to the server. Find it (likely `apps/plot/lib/store/thread.dart` and/or a sync layer) by searching for how an existing scalar/array thread column (e.g. `topic`, `groups`, `icon`) is read from the server JSON and written back. `team_id` follows the same pattern.
- Switch sites on `ln`: `note_editor.dart`, `widget/thread.dart`, `widget/note.dart`, `page/new_thread.dart`, `command/thread.dart`, `state/thread.dart` (found via `rg -n "case ln\.|ln\.(thread|channel|message)"`).

**Gotcha — `fromStore` drops columns** (`memory: project_fromstore_drops_columns`): `Thread`/`Priority` hand-forward each column to `super(...)`/`_fromStore`. A new column missing from that forwarding list silently resets to null on every `copyWith`/save. When you add `teamId`, forward it **everywhere** `topic`/`groups` are forwarded (factory, `_fromStore`, `copyWith`).

**Gotcha — Drift migrations** (`apps/plot/AGENTS.md`): use a **new** `schemaVersion` number (never reuse a passed version — `memory: feedback_safe_add_column`). Add the column via `m.addColumn(threads, threads.teamId)` in `onUpgrade` for the new version. New nullable column needs no data migration. Run `flutter pub run build_runner build` to regenerate `.g.dart`.

---

### Task 1: Add `ln.none` and handle it everywhere `ln` is switched

**Files:** `apps/plot/lib/store/link.dart` + every `ln` switch site.

- [ ] Add `none` to the `ln` enum and map it in `ln.fromJson` (`'none' => ln.none`). Keep the default fall-through as `ln.thread`.
- [ ] Update **every** `switch`/`case` on `ln` (use `rg -n "case ln\.|switch.*\bln\b" apps/plot/lib` to find them all) so the new variant is handled — Dart exhaustive switches over an enum will fail to compile otherwise. Semantics of `none`: **no recipient roster / no sharing UI.** Concretely:
  - Header/participants (`widget/thread.dart`): treat like a thread with no roster — show no AvatarGroup/channel title (no contacts to show).
  - Note badges (`widget/note.dart`): no divergence badges (like `channel`/`thread`, not `message`).
  - Editor copy (`note_editor.dart`, `new_thread.dart`): same as the default (`thread`) branch unless the connector supplies copy.
  - Anywhere that currently treats `message` specially (per-note access) — `none` is NOT message; group it with the no-op branch.
- [ ] `flutter analyze apps/plot/lib/store/link.dart` and the changed switch files — must be clean (no unhandled-case warnings).

---

### Task 2: Add the `teamId` Drift column + migration

**Files:** `apps/plot/lib/store/thread.dart` (table), `apps/plot/lib/store/store.dart` (version + migration).

- [ ] Add a nullable integer column to the threads Drift table: `IntColumn get teamId => integer().nullable()();` (server `team_id` is `bigint`; the app uses Drift int/Int64 conventions — match how existing bigint-backed columns are typed in this table, e.g. any existing `int` server id).
- [ ] Bump `Store.schemaVersion` to the next number above its current value, and add `if (from < <newVersion>) { await m.addColumn(threads, threads.teamId); }` in `onUpgrade`.
- [ ] `cd apps/plot && flutter pub run build_runner build` (regenerates `.g.dart`). Expect success.

---

### Task 3: Surface `teamId` on the `Thread` model + forward it through `_fromStore`/factory/`copyWith`

**Files:** `apps/plot/lib/store/thread.dart`.

- [ ] Add a `teamId` field/getter to `Thread`. Forward it in the `Thread(...)` factory, `_fromStore(...)`, and `copyWith(...)` — **in the same places `topic`/`groups` are forwarded** (heed the fromStore-drops gotcha). Default `null`.
- [ ] In `finalizeThreadDraft(...)` and the `Thread(...)` factory used by compose, carry `teamId` from the draft (it will be `null` until Phase 5 sets it from the target picker — that's correct for now).

---

### Task 4: Round-trip `teamId` through sync (pull + push)

**Files:** the thread sync parse/serialize code (find it as described in Context).

- [ ] **Pull:** when parsing a `/sync/threads` server row into the local threads table, read `team_id` and write it to `teamId`. Follow the exact pattern used for an existing scalar column (e.g. `topic`).
- [ ] **Push:** when serializing a local thread to send to the server, include `team_id` (from `teamId`). The server treats it as immutable-after-create, so always sending it is safe. Match the casing/shape the server expects (`team_id`; `threads.ts` reads `teamId`/`team_id` — confirm which key the existing push payload uses for snake/camel and match the sibling fields).
- [ ] If the app has a Zod/CBOR/JSON schema or model for the sync payload that enumerates thread fields, add `team_id`/`teamId` there too so it isn't stripped.

---

### Task 5: Verify

- [ ] `cd apps/plot && flutter analyze` is clean on all changed files (run `flutter analyze` and confirm no new errors/warnings in touched files).
- [ ] Grep to confirm no `ln` switch is left non-exhaustive and `teamId` is forwarded in every `_fromStore`/`copyWith`/factory site (compare against `topic`/`groups` occurrences).
- [ ] Do NOT run the full test suite (needs heavy bootstrap); `flutter analyze` on changed files is the bar per project guidance.

---

### Task 6: Commit

- [ ] ```
  cd /Users/kris.braun/code/plot/.claude/worktrees/two-step-thread-creation
  git add apps/plot/lib/store/link.dart apps/plot/lib/store/thread.dart apps/plot/lib/store/store.dart <other changed files incl. .g.dart>
  git commit -m "feat(app): carry thread.teamId through sync; recognize ln.none" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" -- <the same paths>
  ```

## Out of scope (do NOT do here)
- No compose-UI changes (two-step flow, target picker, focus auto-suggest) — Phase 5.
- No removal of `priority.defaultContacts/Groups/InviteEmails` or `priority.teamId` reads, getters, or UI — Phase 5 (UI) + Phase 6 (columns). Leave them working.
- No `thread.externalContacts` on the client — it's server-only (firewall input).

## Acceptance
A thread created locally and synced round-trips `team_id` (null today); `ln.none` is parsed and handled in all switches; `flutter analyze` clean on changed files; no priority-defaults or compose-UI changes.

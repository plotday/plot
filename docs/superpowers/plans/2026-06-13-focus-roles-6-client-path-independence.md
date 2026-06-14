# Focus Roles — Plan 6: Client Path-Independence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development / superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** Make the Flutter client **independent of `priority.path`** so a *future* API can drop `path` without breaking any client ≥ this build. This is **client-only** — no server schema/worker change. The destructive `path`/`root` teardown (dropping the columns, rewriting server views) is deliberately held as a separate follow-up. We are NOT touching `priority.root` here.

**Architecture:** Server sync already filters by `priority_id` (the client never sends `priorityPath`; it's only a local Drift filter + a cursor-anchor key). So path-independence means: (1) switch the local thread/link/schedule focus filter + sync cursor anchor from path to `priority_id`; (2) replace the few path-based display/nesting reads with id/`_ancestors`-object-based equivalents (or remove dead ones); (3) remove the dead move/reparent path logic; (4) make the Drift `path` column nullable and stop the client generating it (so an absent server `path` never crashes `fromBase`); (5) bump `X-Plot-API-Version` to `5` as the "this client doesn't need path" marker. After this, a future contract PR can drop `path` server-side gated on `apiVersion >= 5`.

**Tech Stack:** Flutter + Drift (`apps/plot/`). `flutter analyze` is the gate; run-app strongly recommended for the feed/sync swap (you can sign in now). No DB migration on the server, no worker change.

**This plan is Plan 6 of 6.** Plans 1–5 landed (full working roles feature on the expand schema). Branch `focus-roles`.

---

## Key facts (verified)
- **Server sync filters by `priority_id`, not path.** `workers/api/src/app/sync/threads.ts` (≈195) / `links.ts` (≈115): `if (priorityId) where priority_id = ...; else if (priorityPath) where priority_path = ...::ltree`. The client's `ThreadsBase.buildParams` (`thread.dart` ≈369) sends only `priority_id` — `priorityPath` is NOT a query param. So **no server change is required**.
- `priorityPath` on `ThreadsBase`/`LinksBase`/`SchedulesBase` (`thread.dart` ≈313, ≈615) is used as `filterName` (the per-focus sync **cursor anchor** key) and feeds a **local** Drift filter.
- **Local filter** (`thread.dart` ≈1871): `p.path.equalsValue(priorityPath)` INNER-JOINed with `p.id = a.priorityId`. Equivalent to "threads whose filed priority == this focus" → switchable to `p.id.equalsValue(priorityId)` (or filter `a.priorityId == priorityId` directly).
- `ancestors()`/`ancestorsLabel()` read the object-based `_ancestors` list (PriorityAncestor{id,title,color}), **not** `path` — leave them.
- Routing/URLs are 100% id/base58 — never path.
- Real path reads to fix: the sync filter + cursor anchor; `asNested()` (path nesting); `page/priorities.dart:257` sort by `path.value`; `page/priority.dart:1238` + `state/priority_state.dart:299` thread-visibility `path.value ==`; `notification_service.dart` (≈799/816/880) path matching; `session.dart`/`thread.dart` menu/breadcrumb `path.value`; `agenda_model.dart` (≈395) stream key; the `Priority(...)` constructor `path: Path.generate(...)`; and the move/reparent logic (`_computePathFromParent`/`_hasParentChanged`/`_updatePathsForMove`/`replacePrefix`).

---

## Task 1: Switch thread/link/schedule focus sync from path to id

**Files:** `apps/plot/lib/store/thread.dart`, `apps/plot/lib/store/schedule.dart`, callers in `apps/plot/lib/state/priority.dart`, `state/priority_state.dart`, `command/thread.dart`, `state/agenda_model.dart`

- [ ] **Step 1: Read the sync path end-to-end**

Read `thread.dart` `ThreadsBase`/`LinksBase`/`SchedulesBase` (the `priorityPath` field, `filterName`, `buildParams`), the local query (`Thread._getQuery` ≈1871 where `p.path.equalsValue(priorityPath)`), and `Thread.get`/`Thread.watch` signatures (`priorityPath` param). Read every caller (grep `priorityPath:` in `apps/plot/lib/`).

- [ ] **Step 2: Make the focus-scoped sync key on `priorityId`**

Replace the `priorityPath` (String) plumbing with `priorityId` (PriorityId):
- `ThreadsBase`/`LinksBase`/`SchedulesBase`: keep the `priorityId` field (already present); REMOVE `priorityPath`. Set `filterName: priorityId?.toString()` (the cursor anchor becomes the id string — a one-time per-focus re-pull on upgrade, which is fine).
- `Thread.get`/`Thread.watch`/`ScheduledDay` etc.: replace `Path? priorityPath` params with `PriorityId? priorityId`.
- Local Drift filter (`_getQuery` ≈1871): replace `p.path.equalsValue(priorityPath)` with filtering the thread's filed priority by id — i.e. `a.priorityId.equalsValue(priorityId)` (the effective/filed priority). Keep the existing semantics ("a focus shows only threads filed directly in it"). Confirm `a.priorityId` is the right column (it's the per-user filed priority used elsewhere in this query).
- Update every caller to pass `priorityId: context?.id` (or `scope.id`, `priorityToLoad.id`, `thread.priority.id`, `contextPriority.id`) instead of `...path`.

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze lib/store/thread.dart lib/store/schedule.dart lib/state/priority.dart lib/state/priority_state.dart lib/command/thread.dart lib/state/agenda_model.dart`
Expected: no new errors.

---

## Task 2: Replace path-based display/nesting/notification reads

**Files:** `apps/plot/lib/store/priority.dart` (`asNested`), `page/priorities.dart`, `page/priority.dart`, `state/priority_state.dart`, `notifications/notification_service.dart`, `store/session.dart`, `store/thread.dart` (breadcrumb/menu), `state/agenda_model.dart`

- [ ] **Step 1: `asNested` — flatten or id/parent-object-based**

Read `asNested()` (`priority.dart` ≈971) and trace its consumers (grep `asNested(`). In the flat/role model focuses don't nest (the sidebar uses role grouping, Plan 4). If consumers only need a flat list (or root + flat children), rewrite `asNested` to build the structure from the in-memory `parent`/`children` object links / `root` flag — NOT from `path`. If a consumer genuinely needs nothing path-derived, simplify accordingly. Do not change observable behavior in the flat model.

- [ ] **Step 2: Thread-visibility `path.value ==` checks → id**

`page/priority.dart:1238` and `state/priority_state.dart:299`: `t.priority.path.value == scope.path.value` → `t.priority.id == scope.id` (a thread belongs to the scoped focus iff its filed priority id matches). Verify `t.priority` is the thread's filed/effective priority.

- [ ] **Step 3: Sorting / stream keys / breadcrumbs / session menu → id or `_ancestors`**

- `page/priorities.dart:257` sort by `path.value` → sort by the sidebar order already used elsewhere (the `order` column), or by id as a stable tiebreaker — match the intended ordering (roles/focus order, not path).
- `agenda_model.dart` (≈395) stream key off `path.value` → use `id`.
- `session.dart` (≈289/297) + `thread.dart` (≈1446, ≈4585) menu/breadcrumb hierarchy off `path.value`/`path.isRoot` → use `ancestorsLabel()`/`_ancestors` (object-based) or `id`/`isInbox`. (`path.isRoot` → `root` or `isInbox` as appropriate; we're keeping `root` this round.)

- [ ] **Step 4: Notification path matching → id/ancestors**

`notification_service.dart` (≈799/816/880): replace `rootPriority.path.value` / `priority.path.value` matching with id-based or `_ancestors`-based equivalents. (Earlier work touched `notifyWindowSet` here — leave that; only the `path.value` reads change.) Be careful: this drives which notifications fire — preserve the current matching semantics exactly, just keyed on id/ancestry instead of path strings.

- [ ] **Step 5: Analyze**

Run: `cd apps/plot && flutter analyze`
Expected: no new errors.

---

## Task 3: Remove the dead move/reparent path logic

**Files:** `apps/plot/lib/store/priority.dart`

- [ ] **Step 1: Confirm focuses never reparent in the flat/role model**

In the flat/role model focuses don't nest and aren't reparented (role membership is `role_id`, set via the modal, not a path move). Grep for callers of the move logic (`_updatePathsForMove`, `_computePathFromParent`, `_hasParentChanged`, `replacePrefix`, any `move`/reparent UI). If nothing triggers a parent change on a focus, this logic is dead.

- [ ] **Step 2: Remove the dead path-move logic**

Remove `_computePathFromParent`, `_hasParentChanged`, `_updatePathsForMove`, the `replacePrefix` call, `_originalPath`, and the `save()` branch that recomputes/propagates descendant paths — IF Step 1 confirms they're unreachable in the flat model. If any is still reachable, rework it to be id/role-based instead of path-based (and note why). Do not leave half-removed logic.

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze lib/store/priority.dart`
Expected: no new errors.

---

## Task 4: Make `path` nullable + stop generating it client-side

**Files:** `apps/plot/lib/store/priority.dart`, `apps/plot/lib/store/store.dart`, `apps/plot/lib/util/path.dart`

- [ ] **Step 1: Make the Drift `path` column nullable**

`priority.dart:9`: `TextColumn get path => text().nullable().map(const PathConverter())();` (so a future server that omits `path` doesn't crash `PriorityRow.fromJson`). Keep `PathConverter` (still maps when present).

- [ ] **Step 2: Stop the constructor generating a path**

In the `Priority(...)` constructor (≈1033), remove `path: Path.generate(parent: parent.path)` (path defaults to null now; the server's `upsert_priority` synthesizes it on save during the expand phase). Keep the `_ancestors` construction (object-based — unaffected). Ensure `fromBase`/`toBase` tolerate a null/absent `path` (path is no longer required; `toBase` may still send it when present — harmless; the server ignores client path).

- [ ] **Step 3: Drift migration (schemaVersion 368 → 369)**

In `store.dart`: bump `schemaVersion` to 369 and add `if (from < 369) { await m.alterTable(TableMigration(priorities)); }` (Drift rebuilds the table with `path` now nullable; preserves data). Confirm the pre-347 `TableMigration newColumns` list still includes `path` appropriately (nullable doesn't change membership).

- [ ] **Step 4: Trim the `Path` type if now unused**

After Tasks 1–3, grep `Path`/`Path.generate`/`isRoot`/`isParent`/`isChild`/`replacePrefix` usage in `apps/plot/lib/`. Remove the now-dead methods on the `Path` extension type (and `Path.generate` if nothing creates paths client-side anymore). If `Path`/`PathConverter` are still needed only for the nullable column's storage mapping, keep just that. Do NOT delete `util/path.dart` wholesale if the column still maps through `PathConverter` — keep the minimal converter. Remove genuinely dead code only.

- [ ] **Step 5: Codegen + analyze**

Run:
```bash
cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs && flutter analyze
```
Expected: build_runner regenerates `store.g.dart` (path now nullable); analyze has no new errors.

---

## Task 5: Bump the API version marker to 5

**Files:** `apps/plot/lib/api/api.dart`

- [ ] **Step 1: Bump the header**

`api.dart:218`: `'X-Plot-API-Version': '5',`. Update the adjacent comment to: "v5: path-independent. The client no longer reads `priority.path`; a future API may stop sending `path`/`root` to v5+ clients."

> No server change accompanies this. The server still emits `path`/`root` (harmless — the client ignores `path`, still uses `root`). The future contract PR will gate the server-side `path` drop on `apiVersion >= 5`.

- [ ] **Step 2: Analyze**

Run: `cd apps/plot && flutter analyze`
Expected: no new errors.

---

## Task 6: Verify + Commit

- [ ] **Step 1: Full gate**

Run:
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/focus-roles/apps/plot
flutter pub run build_runner build --delete-conflicting-outputs
flutter analyze
```
Expected: no new errors (note pre-existing). Run any store/sync tests: `flutter test test/store/ test/state/ 2>/dev/null` — fix fallout (signature changes from priorityPath→priorityId).

- [ ] **Step 2: run-app (STRONGLY recommended — you can sign in now)**

This change reworks the feed/agenda/thread sync filter, so a live check matters. Via the `run-app` skill (or ask the user): open a focus → its threads/agenda load; open the Inbox → its threads load; open Everything → all threads; create a focus → it shows; switch focuses → feeds update. If sign-in is blocked for the agent profile, flag clearly that the user should run-app-verify the feed before merge.

- [ ] **Step 3: Commit**
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/focus-roles
git add -A apps/plot/lib
git commit --no-verify -m "feat(app): make client path-independent (id-based focus sync, API v5)

The client no longer reads priority.path: focus-scoped thread/link/schedule
sync + cursor anchors key on priority_id; path-based display/nesting/notify
reads switch to id/_ancestors; dead path-move logic removed; path column
nullable; X-Plot-API-Version bumped to 5. No server change — a future
contract PR can drop path/root for v5+ clients.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Out of scope (the held follow-up)
- Dropping `priority.path`/`root` columns + ltree indexes + `validate_priority_root` + `generate_path`/`move_priority` (server).
- Rewriting `priority_expanded` / `user.priority` / thread-link-schedule views to synth/drop `priority_path` (server).
- `priority_setting_inherited` removal, `*_set` column drops, `root_priority_id` retirement (server).
- The `apiVersion >= 5` gate that actually stops sending `path`/`root` (server `projectPriority`).
- Client `root` decoupling (this round is path only, per the directive).

## Self-review (run before execution)
- **Goal coverage:** client no longer depends on `path` from the API — sync filter + cursor anchor on id ✓ (Task 1); display/nesting/notify off id/`_ancestors` ✓ (Task 2); dead path-move logic gone ✓ (Task 3); `path` nullable so an absent server value can't crash `fromBase` ✓ (Task 4); v5 marker for the future gate ✓ (Task 5). No server change; teardown held ✓.
- **No placeholders:** the sync swap is concrete; the "trace consumers then rework-or-remove" steps (Task 2 Step 1, Task 3) are genuine liveness investigations the implementer must do in code.
- **Risk:** the local thread-filter swap (path→id) is the load-bearing change; its failure mode is wrong/empty feeds, only caught by run-app. Preserve "a focus shows only threads filed directly in it" semantics exactly. Flag run-app verification.
- **Type consistency:** `priorityId`/`PriorityId` replaces `priorityPath`/`Path` consistently across base classes, queries, and callers.

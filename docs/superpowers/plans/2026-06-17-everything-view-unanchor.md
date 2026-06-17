# Un-anchor the Everything View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the synthetic "Everything" view truly context-less — `context == null` instead of secretly anchored on the default Inbox focus — so the app stops pretending you're "in" a focus when you're viewing everything.

**Architecture:** The priority page is driven by `PriorityBloc`/`PriorityState`. Today, opening Everything keeps `PriorityState.context` set to the default Inbox so drafts/feed/header have something to read. We make `PriorityState.context` nullable and enforce the invariant **`everything == true` ⟺ `context == null`**. Every reader of `context` then either (a) already widens for `everything` (feed/agenda — just stop dereferencing a null), (b) renders the "Everything" label (header/title/window), (c) is disabled (per-focus actions/menus/tracking), or (d) — only for composing — falls back to a concrete target. `NowState.context` is *already* `Priority?` and already guarded in the key spots.

**Tech Stack:** Flutter, flutter_bloc, Drift, auto_route, forui. Tests: `flutter_test` + `Store.forTesting(NativeDatabase.memory())`.

**Decomposition note (Option A — atomic flip):** Flutter compiles the whole package for any test, and making `PriorityState.context` nullable turns every unguarded `state.context.id` into a compile error. Therefore the type flip **and every reader guard land together in Task 1** so the package stays build-green and Task 1's tests actually run. Tasks 2–4 layer on top. Do not split Task 1 — a partial reader sweep does not compile.

## Global Constraints

- Flat role model. `Priority.root` no longer exists. The single "home"/default Inbox is `Priority.defaultInbox(List<Priority>) -> Priority?` (`lib/store/priority.dart`) — the oldest `is_inbox` focus.
- **Invariant:** in `PriorityState`, `everything == true` iff `context == null`. Assert it in the constructor. Never construct `everything==false && context==null`, never `everything==true && context!=null`.
- **Compose is the one exception that must keep working from Everything.** A draft with no context resolves its target as: existing MRU suggestion for the chosen people/roster (current flow, unchanged) → else `Priority.defaultInbox(priorities)`. No "force the user to choose" UI.
- **Everywhere else that needs a context but has none:** disable the action/command (not-runnable / hidden control) OR render the branded "Everything" label. Never NPE, never silently retarget a focus action to the Inbox.
- forui widgets only; Bloc read in pages/commands, not widgets. TDD; commit per task.
- The route still carries the default-Inbox id for URL/back; only the **bloc's `context`** goes null when `everything`. A dedicated id-less Everything route is out of scope.

## File Structure

- `lib/state/priority_state.dart` — `context` → `Priority?`; invariant assert; `draftFallbackPriority` for the null-context draft.
- `lib/state/priority.dart` — guard the ~13 `PriorityBloc` readers (feed query, `currentId`, `setPriority`, feed sync/load); produce a null-context everything state with `draftFallbackPriority = Priority.defaultInbox(...)`.
- `lib/widget/unified_header.dart` — show "Everything" / hide tracking pill when context null.
- `lib/widget/agenda.dart` — null-guard `:357`; `:414` default priority falls back to `defaultInbox`.
- `lib/command/thread.dart` — `:123/:301/:309/:2196` guard "move to current focus" when context null.
- `lib/state/now.dart` + `lib/command/priority.dart` + `lib/widget/priorities_list.dart` — entry point (Task 2).
- `lib/page/new_thread.dart` + `lib/state/compose_targets.dart` — compose fallback lock-in (Task 3).

---

### Task 1: Atomic null-context flip + all reader guards (build-green)

**Files:**
- Modify: `lib/state/priority_state.dart` (field `:143`, factory `:9-46`)
- Modify: `lib/state/priority.dart` (`:819, :967, :1171, :1646, :1788, :2441, :2735, :2761, :2765-2766, :3657, :3782, :4236`, and the everything-state construction site)
- Modify: `lib/widget/unified_header.dart` (`:687, :918, :974, :984, :989`)
- Modify: `lib/widget/agenda.dart` (`:357, :414`)
- Modify: `lib/command/thread.dart` (`:123, :301, :309, :2196`)
- Test (new): `test/state/priority_everything_context_test.dart`

**Interfaces:**
- Produces: `PriorityState.context : Priority?`; invariant `everything == (context == null)`; factory param `Priority? draftFallbackPriority` (used only when `context == null`); `PriorityBloc.currentId : PriorityId?`. The `PriorityBloc`, when in everything mode, emits `PriorityState(context: null, everything: true, draftFallbackPriority: Priority.defaultInbox(<loaded priorities>))`.
- Consumes: `Priority.defaultInbox(List<Priority>) -> Priority?`.

**Background the implementer needs:** This is the atomic type change — every guard MUST land in this one task or the package won't compile and no test can run (Flutter compiles the whole package). Read each enumerated site live before editing — line numbers may have drifted; find the access expression. The everything feed already widens when `everything == true`; the guards just stop dereferencing a null context and route to that existing unscoped path.

- [ ] **Step 1: Write the failing tests** (in `test/state/priority_everything_context_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';

void main() {
  Priority focus(String title, {bool isInbox = false}) => Priority.fromStore(
        PriorityRow(
          id: Uuid.generate(),
          createdBy: Uuid.generate(),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          title: title,
          path: Path(title.toLowerCase()),
          order: const Order(0),
          unread: false,
          role: 'member',
          isInbox: isInbox,
          isFyi: false,
          attentionWindowSet: false,
          seeWithinSet: false,
          earlyNotificationsEnabledSet: false,
          notifyWindowSet: false,
        ),
        draft: true,
      );

  test('everything state: null context, files draft under the fallback', () {
    final inbox = focus('Inbox', isInbox: true);
    final state = PriorityState(
      context: null,
      everything: true,
      draftFallbackPriority: inbox,
    );
    expect(state.context, isNull);
    expect(state.everything, isTrue);
    expect(state.draft.priority.id, inbox.id);
  });

  test('focus state: non-null context, invariant holds', () {
    final work = focus('Work');
    final state = PriorityState(context: work, everything: false);
    expect(state.context, isNotNull);
    expect(state.everything, isFalse);
    expect(state.draft.priority.id, work.id);
  });

  test('invariant is asserted', () {
    expect(
      () => PriorityState(context: null, everything: false),
      throwsA(isA<AssertionError>()),
    );
  });
}
```

- [ ] **Step 2: Run to verify it fails** — `cd apps/plot && flutter test test/state/priority_everything_context_test.dart` → FAIL to compile (`context` non-null; no `draftFallbackPriority`).

- [ ] **Step 3: Implement the field + invariant + draft fallback** (`priority_state.dart`)

```dart
final Priority? context;            // was: final Priority context;
// in the factory body, BEFORE `draft ??= ...`:
assert((context == null) == everything,
    'PriorityState invariant: everything <=> context == null');
final draftPriority = context ?? draftFallbackPriority;
assert(draftPriority != null, 'a context-less state needs a draftFallbackPriority');
draft ??= Thread(priority: draftPriority!, draft: true);
```
Add `Priority? draftFallbackPriority` to the factory params; thread the nullable `context` through `copyWith`/private ctor.

- [ ] **Step 4: Guard every `PriorityBloc` reader** (`priority.dart`) — read each site live, apply:

| Site | Current | Replacement |
| --- | --- | --- |
| `:967`, `:2441` `currentId` | `=> state.context.id;` | `PriorityId? get currentId => state.context?.id;` |
| `:1646` | `feedContextId: state.context.id,` | `feedContextId: state.context?.id,` (widen callee param to `PriorityId?`; when null, omit the `priority_id = ?` filter — reuse the existing `everything` unscoped path) |
| `:819, :1171, :1788, :4236` | `context: state.context,` / `state.context.id,` | pass the nullable value / `state.context?.id`; widen callee to tolerate null = unscoped |
| `:2735` | `if (state.context.id == newPriority.id) return;` | `if (state.context?.id == newPriority.id) return;` |
| `:2761` | `'${state.context.title} -> …'` | `'${state.context?.title ?? 'Everything'} -> …'` |
| `:2765-2766` | `if (!state.context.isInbox) { _previousContextPriority = state.context; }` | `final prev = state.context; if (prev != null && !prev.isInbox) { _previousContextPriority = prev; }` |
| `:3657` | `_pendingFeedSync = state.context;` | ensure the field is `Priority?`; no deref |
| `:3782` | `final priorityToLoad = state.context;` | `final Priority? priorityToLoad = state.context;` + skip the per-focus load branch when null (the everything branch handles loading) |

At the everything-state construction site in `PriorityBloc` (where it emits a state with `everything: true`), pass `context: null, everything: true, draftFallbackPriority: Priority.defaultInbox(<the loaded priorities list this bloc already holds>)`. If the bloc lacks the list, `await Priority.getRaw(order: PriorityOrder.recent)`.

- [ ] **Step 5: Guard the widget/agenda/command readers**
  - `unified_header.dart:687/:918`: `if (state.context != null) _PriorityHeaderTrackingControl(priority: state.context!) else const SizedBox.shrink(),`
  - `unified_header.dart:974/:984/:989`: ensure the existing `if (state.everything)` branch is reached before any `state.context!`; the non-everything path keeps `state.context!` (invariant guarantees non-null).
  - `agenda.dart:357`: `final ctxId = context.read<PriorityBloc>().state.context?.id;` then guard the block-selection use when null.
  - `agenda.dart:414`: `defaultPriority: priorityBloc.state.context ?? Priority.defaultInbox(context.read<PrioritiesBloc>().state.priorities),`
  - `thread.dart:123/:301/:309/:2196`: read into a local `final current = priorityBloc?.state.context;` then `if (current == null) return /* not-runnable / skip */;` before any `current.` use.

- [ ] **Step 6: Run the new test + file-scoped analyze**

Run: `cd apps/plot && flutter analyze lib/ && flutter test test/state/priority_everything_context_test.dart`
Expected: analyze clean (only the pre-existing `use_build_context_synchronously` info at `new_thread.dart`); the 3 tests PASS.

- [ ] **Step 7: Run the broader affected suites to confirm no regression**

Run: `cd apps/plot && flutter test test/state test/store`
Expected: green except the documented pre-existing failures (4 migration tests, flaky `infinite_list`, `note_editor_top_bar` Provider-wiring).

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/state/priority_state.dart apps/plot/lib/state/priority.dart apps/plot/lib/widget/unified_header.dart apps/plot/lib/widget/agenda.dart apps/plot/lib/command/thread.dart apps/plot/test/state/priority_everything_context_test.dart
git commit -m "refactor(app): null context for the Everything view (everything <=> context == null)"
```

---

### Task 2: Entry point — open Everything with a null context

**Files:**
- Modify: `lib/command/priority.dart` (`ChangeCurrentPriority` `:85-103`)
- Modify: `lib/widget/priorities_list.dart:209`
- Modify: `lib/state/now.dart:437-505` (`setContext` — accept `null` + `everything: true`; skip watermark/distraction when priority null)
- Test (new): `test/state/everything_entry_test.dart`

**Interfaces:**
- Consumes: Task 1's null-context `PriorityState`.
- Produces: `ChangeCurrentPriority.everything()` — a named ctor taking no `Priority`; its `run` calls `nowBloc.setContext(null, everything: true)` and navigates to the priority page in everything mode (reuse `PriorityRoute` with `Priority.defaultInbox(...)?.id` for the URL).

- [ ] **Step 1: Write the failing test** — running the Everything entry yields `NowState.everything == true && NowState.context == null`.

```dart
// Model NowBloc setup on an existing test/state/*now* test. Assert:
// after setContext(null, everything: true), state is NowLoaded with
// everything == true and context == null, and no exception is thrown.
```

- [ ] **Step 2: Run → FAIL** (today `setContext` paths assume a non-null priority for the everything entry; the sidebar passes `widget.root`).

- [ ] **Step 3: Implement**
  - Add `ChangeCurrentPriority.everything()` (no `Priority` arg). Its `run`: `nowBloc.setContext(null, everything: true)`; navigate via `PriorityRoute(priorityIdString: Priority.defaultInbox(<priorities>)?.id?.toShortString())` flagged everything (mirror however the page reads everything today). Keep the existing `ChangeCurrentPriority(Priority, {everything})` ctor for normal focus navigation.
  - `priorities_list.dart:209`: `command: ChangeCurrentPriority.everything(),` (drop `widget.root`).
  - `now.dart`: in `setContext`, allow `priority == null` with `everything == true`; the watermark update (`~:452`) and distraction start (`~:496`) must no-op when `priority == null`.

- [ ] **Step 4: Run → PASS**; `flutter analyze lib/` clean.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/command/priority.dart apps/plot/lib/widget/priorities_list.dart apps/plot/lib/state/now.dart apps/plot/test/state/everything_entry_test.dart
git commit -m "feat(app): open Everything with a null context (no focus anchor)"
```

---

### Task 3: NewThreadPage composes from Everything via MRU → defaultInbox

**Files:**
- Modify (only if a gap exists): `lib/page/new_thread.dart:800-828`, `:1444-1491`
- Test (new): `test/page/new_thread_everything_default_test.dart`

**Interfaces:**
- Consumes: Task 1's `draftFallbackPriority` (= `Priority.defaultInbox`); the existing MRU suggestion flow (`_suggestFocusForTarget` / `rankFocusesForRoster`).

**Background:** with a null context the draft is born against `draftFallbackPriority` (Task 1 = default Inbox). The MRU suggestion already runs when the user picks people/roster and re-files the draft; `:1484` skips Inbox focuses, so when MRU yields nothing the draft stays on the fallback Inbox. This task is primarily a **lock-in test**; only add code if the default-priority resolution can leave `draft.priority` null when context was null.

- [ ] **Step 1: Write the locking test** — compose opened from Everything (null context), no remembered default, people-target with no MRU history → `draft.priority` resolves to `Priority.defaultInbox(priorities)`; with MRU history → the MRU focus.

- [ ] **Step 2: Run** — if it FAILS, there's a gap; if it PASSES, Task 1 already covers it and this task only locks it in.

- [ ] **Step 3: Implement any gap** — if `_applyQueryParametersToDraft` can leave `draft.priority` null when context was null, add: `bloc.state.draft.priority ??= Priority.defaultInbox(await Priority.getRaw(order: PriorityOrder.recent));`. Otherwise no code change.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart apps/plot/test/page/new_thread_everything_default_test.dart
git commit -m "test(app): lock NewThreadPage Everything compose fallback (MRU -> defaultInbox)"
```

---

### Task 4: Full verification

**Files:** `docs/updates.md` (one bullet); no code.

- [ ] **Step 1:** `cd apps/plot && flutter analyze lib/` → only the pre-existing `use_build_context_synchronously` info.
- [ ] **Step 2:** `flutter test test/store test/state test/widget test/command` → green except documented pre-existing failures.
- [ ] **Step 3:** run-app smoke (run-app skill from the worktree): open Everything → header reads "Everything", Everything tile selected, no tracking pill, `get_runtime_errors` empty; start a thread from Everything → lands in the default Inbox (or the MRU focus once people are picked); open a real focus → context restored, per-focus chrome returns. Screenshot each.
- [ ] **Step 4:** Add a `docs/updates.md` Fixes/feature bullet: "The Everything view is now a true cross-focus view rather than secretly tied to your Inbox; starting a thread from it files into your main Inbox unless you pick a focus." Commit.

---

## Self-Review

**Spec coverage:** null-context honest model + all reader guards → Task 1 (atomic). Entry point → Task 2. Compose exception (MRU→defaultInbox) → Task 1 draft init + Task 3 lock-in. Disable-or-label rule → Task 1 (header label, per-focus disable). Verification → Task 4. ✓

**Decomposition:** Task 1 is intentionally large (atomic type flip — cannot be split and stay build-green, per the Decomposition note). Tasks 2–4 are small and each build-green.

**Type consistency:** `context : Priority?`; `currentId : PriorityId?`; `draftFallbackPriority : Priority?`; `Priority.defaultInbox(List<Priority>) -> Priority?` used as the compose/agenda fallback throughout.

**Live-read flags for the implementer:** the `PriorityBloc` everything-construction site and the feed-query callee signatures (`feedContextId`, `_loadActivityFeed`) must be read live before widening to nullable — line numbers may have drifted.

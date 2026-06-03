# Phase 5 — Two-step compose UI — Implementation Plan

> **For agentic workers:** Implementer brief, decomposed into three reviewable sub-tasks (5a → 5b → 5c). Contracts are precise (from spec Parts A/C/D + the Phase 4 substrate); the wiring lives in large Flutter files you must read and adapt to. Run via subagent per sub-task with review between. Steps use `- [ ]`. Imports: only `flutter/widgets.dart` + `forui/forui.dart`.

**Goal:** Turn `NewThreadPage` into a two-step flow — step 1 picks a *target* (inline, reusing the connection-picker content), step 2 is today's compose surface with the editor auto-focused and fields reordered **Connection → Focus → Contacts**. Simplify Plot types to **Note**/**Chat** (drop Task), hide the contacts field for no-roster targets, replace Auto-organize with an MRU-suggested focus, drive the picker from the Phase 4 `ComposeTargetsBloc`, and remove the now-defunct per-focus default-contacts UI.

**Architecture:** Reuse the compose field-row widgets (2026-05-25 redesign) and the `SelectModal`-based connection picker; extract its list+search+keyboard body into a `TargetPickerList` widget mountable both inline (step 1) and in a modal (step-2 re-open). Consume `ComposeTargetsBloc` (Phase 4) for the ranked list + search and record a target's signature on submit. `thread.teamId` (Phase 3) carries the chosen team.

**Working directory:** `/Users/kris.braun/code/plot/.claude/worktrees/two-step-thread-creation` (branch `two-step-thread-creation`). Confirm `pwd && git branch --show-current` first. No DB commands needed in this phase.

## Read first (all sub-tasks)
- `apps/plot/lib/page/new_thread.dart` — `_buildComposeSurface` (field rows Priority→Connection→Contacts→Title→Body), `_selectPriority`, `_openConnectionPicker`, `_openSharedPicker`, `_resolveActiveConnectionChoice`, `_applyConnectionChoice`, `_selectTwist`, the submit path, `ThreadsBase.autoFileIds` (auto-organize), `_applyLastUsedConnectionDefault`.
- `apps/plot/lib/widget/compose/` — `ConnectionComposeField`, `PriorityComposeField`, `ContactsComposeField`, `TitleComposeField`, `connection_choice.dart` (`PlotThreadKind`, `PlotThreadChoice`, `TargetConnectionChoice`, `TwistConnectionChoice`).
- `apps/plot/lib/widget/select_modal.dart` — `SelectModal<T>`/`_SelectModal` (the list+search+`ListViewSelector`+`Shortcuts`/`Actions` body to extract) and its modal-shell couplings (`Modal.pop`, `ModalProvider`, reserved close-button space).
- `apps/plot/lib/widget/connection_targets.dart` + `apps/plot/lib/state/compose_targets.dart` + `apps/plot/lib/widget/compose/compose_target.dart` (Phase 4: `ComposeTarget`, `ComposeTargetsBloc.refresh/search/recordTarget/prependToCache`, `toConnectionChoice()/toUserAction()`).
- `apps/plot/lib/store/thread.dart` — `finalizeThreadDraft`, the `Thread(...)` factory (`teamId` param from Phase 3; the `inheritedDefaultShared*` seeding to remove in 5c), `Thread.resolveln`.
- `apps/plot/lib/store/priority.dart` — `inheritedDefaultSharedContacts/Groups/InviteEmails` getters; the priority-settings UI editing `defaultContacts/Groups/InviteEmails` (find via `rg -n "defaultContacts|defaultShared|default_contacts"`).

---

## Sub-task 5a — Note/Chat only; no-roster contacts hidden

**Scope:** type simplification + no-roster sharing UI. Contained; commit + review before 5b.

- [ ] **Drop Task:** in `connection_choice.dart`, reduce `PlotThreadKind` to `{ note, chat }`; remove `plotTask` and `PlotThreadChoice.plotTask`/`plotForKind(task)`. Update `label` to `"Note"`/`"Chat"` (drop the "Plot " prefix) and `key` to `plot:note`/`plot:chat`. Fix every reference to `PlotThreadKind.task`/`plotTask` (`rg -n "plotTask|PlotThreadKind.task|Plot note|Plot chat|Plot task"`). The first-note-as-todo behavior on create is removed (the spec keeps post-create to-do tagging, which is unaffected — don't touch the thread to-do toggle).
- [ ] **No-roster targets hide the contacts field:** in `_buildComposeSurface` (and wherever the contacts row visibility is decided), hide `ContactsComposeField` when the active target is a **Note** OR a connector target whose `LinkTypeConfig.sharingModel == SharingModel.none` (Google Tasks). Resolve the model via `Thread.resolveln`/the active `CreateTarget`'s linkType. For **Chat** and `thread`/`channel`/`message`/DM/address targets, keep current behavior.
- [ ] Update editor placeholder/copy paths that switched on the dropped Task kind so they compile and read sensibly (Note → "Add a note", Chat → "Start a chat"; connector copy unchanged).
- [ ] **Verify:** `flutter analyze` clean on changed files; `rg` shows no remaining `plotTask`/`PlotThreadKind.task`/"Plot note"/"Plot chat" references.
- [ ] **Commit:** `feat(app): Note/Chat thread types (drop Task); hide contacts for no-roster targets`.

---

## Sub-task 5b — Two-step flow, `TargetPickerList`, MRU + focus auto-suggest

**Scope:** the core restructure. This is the largest unit.

- [ ] **Extract `TargetPickerList`** (`apps/plot/lib/widget/compose/target_picker_list.dart`): factor the list+search+keyboard-navigation body out of `_SelectModal` into a standalone widget that takes items/search callbacks + an `onSelect(ComposeTarget)` callback + external focus/scroll controllers, and does NOT call `Modal.pop` or read `ModalProvider`. Keep keyboard nav identical (↑/↓ highlight, Enter select, type-to-filter — reuse the existing `ListViewSelector`/`Shortcuts`/`Actions`). The existing connection modal becomes a thin `Modal` hosting `TargetPickerList`; step 1 mounts the same widget inline (search field styled to sit on the page, not as a modal header). Prefer refactoring `_SelectModal` to delegate to `TargetPickerList` over copy-paste, so both paths share one implementation.
- [ ] **Wire `ComposeTargetsBloc`:** register the Phase 4 provider in the app's provider tree (where the compose/priority blocs are provided). `TargetPickerList` reads `ComposeTargetsBloc.refresh()`'s ranked list and routes the search box through `ComposeTargetsBloc.search(query)`.
- [ ] **Two-step state machine in `NewThreadPage`:** on fresh mount show only the inline `TargetPickerList` (step 1). Selecting a `ComposeTarget` applies it (set draft `teamId`; attach `CreateLinkUserAction`/select twist via `ComposeTarget.toConnectionChoice()`/`toUserAction()` reusing `_applyConnectionChoice`/`_selectTwist`; prefill `contacts`/`groups`) and transitions to step 2.
- [ ] **Step 2 layout:** today's compose surface with field order **Connection → Focus → Contacts → Title → Body**; **auto-focus the note editor** on entry (both single- and multi-panel branches). The connection field shows the chosen target's label and **re-opens `TargetPickerList` in a modal** on tap; choosing a new target re-applies and stays on step 2. Contacts row hidden per 5a's no-roster rule.
- [ ] **Focus auto-suggest, no Auto-organize:** remove the Auto-organize entry from the focus picker and `ThreadsBase.autoFileIds` usage in this flow. On entering step 2, pre-select a concrete focus = the MRU-top focus for the target's contacts/groups (rank focuses by recency of threads filed with those same contacts/groups — derive from recent threads, or reuse `LocalPreferencesBloc.rankConnectionsByMru`'s per-priority data / a focus-MRU helper). The focus picker lists focuses in that MRU order. (Server-side auto-classification of synced connector threads via `channel.default_priority_id` is unaffected — don't touch it.)
- [ ] **Record on submit:** in the submit path, call `ComposeTargetsBloc.recordTarget(...)` with the chosen target's full signature (replacing/augmenting the existing `recordConnectionUsage` call) and `prependToCache` so the next New-thread reflects it. Record globally (no priority bias).
- [ ] **Fresh start:** the New-thread command (`command/thread.dart`) always remounts step 1 (state in `NewThreadPageState` inits to step 1). A remembered last target may pre-highlight within step 1 but must not skip it.
- [ ] **Verify:** `flutter analyze` clean on changed files; keyboard nav works in both inline and modal `TargetPickerList`.
- [ ] **Commit:** `feat(app): two-step thread compose (target picker + MRU + focus auto-suggest)`.

---

## Sub-task 5c — Remove per-focus default-contacts UI + seeding

**Scope:** retire the feature the new flow replaces. (Drift/DB columns are dropped in Phase 6; here just stop using/showing them.)

- [ ] Remove the `inheritedDefaultShared*` **seeding** in the `Thread(...)` factory / `finalizeThreadDraft` (new threads no longer auto-seed priority default contacts/groups/invite-emails). Keep the `Priority` getters compiling for now if other code reads them, but remove their use in compose.
- [ ] Remove the priority-settings **UI** that edits `defaultContacts`/`defaultGroups`/`defaultInviteEmails` (the form fields / section). Leave the Drift columns + `upsert_priority` passthrough intact (Phase 6 removes them) so sync/back-compat is unaffected this phase.
- [ ] **Verify:** `flutter analyze` clean; creating a thread no longer pulls in focus default contacts; no dangling references to the removed UI.
- [ ] **Commit:** `feat(app): remove per-focus default-contacts UI (superseded by target picker)`.

---

## Phase 5 acceptance (verified by running the app)
- New-thread opens on the inline target picker (step 1); arrow/Enter/type-to-filter work; the list shows Note/Chat (per team) + connector combos in MRU order; typing a name/email surfaces synthesized targets.
- Selecting a target → step 2 with the editor focused, fields ordered Connection → Focus → Contacts; tapping Connection re-opens the picker.
- Note (and Google Tasks) show no contacts field; Chat does; team parenthetical only with ≥1 team; connection parenthetical only with >1 connection.
- Focus is always a concrete MRU-suggested value (no Auto-organize); changing the target re-suggests.
- New-thread always starts on step 1; creating a thread records its target and it floats to the top next time.
- No per-focus default-contacts UI remains; `flutter analyze` clean.

## Out of scope
Dropping `priority.team_id`/`default_*` DB+Drift columns and the `priority_team`/team-focus triggers — Phase 6.

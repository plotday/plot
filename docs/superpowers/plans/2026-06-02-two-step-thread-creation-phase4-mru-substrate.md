# Phase 4 — Target MRU substrate — Implementation Plan

> **For agentic workers:** Implementer brief. The contract (model, signature, ranking, search rules, cache) below is precise and from the spec; the exact wiring lives in live Flutter files you must read and adapt to. Bloc/service-level only — **no compose-UI changes** (that's Phase 5). Use TDD with bloc unit tests. Steps use `- [ ]`.

**Goal:** Produce the data layer behind the step-1 target picker: a materialized, **globally MRU-ranked** list of "compose targets" (every Plot Note/Chat variant + every connector connection/channel/DM combination the user has used or can use), plus a search function that synthesizes contact- and email-specific targets on demand. Cached in app state and updated when a thread is created. No UI.

**Architecture:** Extend the existing connection-MRU infra (`LocalPreferencesBloc.connectionMru` / `rankConnectionsByMru` / `recordConnectionUsage` / `lastUsedConnectionKey`, built by the 2026-05-29 last-used-connection work) with (a) a richer **target signature** that includes team + contacts/groups, and (b) a **global** (priority-less) ranking. Add a `ComposeTargets` provider/service that materializes the ranked list from multiple stores (connections, channels, teams, contacts, recent authored threads) combined with that MRU recency, and serves search.

**Tech Stack:** Flutter/Dart, Bloc, Drift stores. Imports: only `flutter/widgets.dart` + `forui/forui.dart`.

**Working directory:** `/Users/kris.braun/code/plot/.claude/worktrees/two-step-thread-creation` (branch `two-step-thread-creation`). Confirm with `pwd && git branch --show-current`.

---

## Read these first (adapt the contract to their real shapes)

- `apps/plot/lib/state/local_preferences.dart` — `connectionMru` (`Map<String, ConnectionMruEntry>` with global `lastUsedMs` + per-priority `priorityLastUsedMs`), `recordConnectionUsage({channelKey, priorityId})`, `rankConnectionsByMru({keys, priorityId})`, `lastUsedConnectionKey({candidateKeys, priorityId})`.
- `apps/plot/lib/widget/connection_targets.dart` — `CreateTarget` (its `key`, `chipLabel`, `searchText`, `linkType`, `toUserAction()`, `isDmType`/address/channel flags) and how connections+channels are loaded into targets (`loadCreateTargets`/`_allConnectionTargets`). `LinkTypeConfig.compose.targets` ∈ `channels|contacts|addresses` declares capability.
- `apps/plot/lib/widget/compose/connection_choice.dart` — `ConnectionChoice` (`PlotThreadChoice` note/chat — Task is dropped in Phase 5, ignore it here; `TargetConnectionChoice`; `TwistConnectionChoice`) and the `_scopeSuffix` parenthetical pattern.
- `apps/plot/lib/store/actor.dart` — `authoredThreadsForSharing(...)` + `getSortedForSharing`/`getSortedShareCandidates` banding (the "authored/replied" correspondent filter that excludes send-only addresses). Reuse this for name/email search.
- `apps/plot/lib/store/thread.dart` — how a thread records its origin so a recent thread → target signature: primary `link` (`createdBy` = twist_instance, `channelId`), `thread.contacts`/`groups`/`teamId`. `apps/plot/lib/store/link.dart`, `channel.dart` for channel title/recency.
- The team store/bloc — how to list the user's teams (for `Note`/`Chat` per team) and team names. Find it (`rg -n "class .*Team|team" apps/plot/lib/store apps/plot/lib/state`).
- Look for an existing bloc/service that combines multiple stores for a pattern to follow when structuring `ComposeTargets`.

---

### Task 1: Define the `ComposeTarget` model

**File:** new `apps/plot/lib/store/compose_target.dart` (or beside `connection_targets.dart` if that fits conventions better).

- [ ] Define an immutable `ComposeTarget` (use `equatable`):
  - `kind`: enum `{ note, chat, connector, twist }`.
  - `connection`: `TwistInstance?` (the connector connection; null for note/chat).
  - `linkType`/`channel`: connector link type id + optional `Channel` (channel connectors); null otherwise.
  - `teamId`: `BigInt?` — `null` = Personal. For note/chat it's the chosen team; for connector targets it's inherited from `connection.teamId`.
  - `contacts`: `List<Uuid>` and `groups`: `List<Uuid>` — optional pre-filled roster (chat / DM / address combos); empty for bare templates.
  - `signature`: stable string key (see Task 2).
  - `label`: display string per the parenthetical rules (Task 3).
  - A way to map a selection back to what Phase 5 needs: expose enough (`kind`, `connection`, `linkType`, `channel`, `teamId`, `contacts`, `groups`) that Phase 5 can apply it to a draft (set team, attach `CreateLinkUserAction` via the existing `TargetConnectionChoice.toUserAction()` path, prefill contacts). Provide a `toConnectionChoice()` / `toUserAction()` bridge reusing the existing `ConnectionChoice`/`CreateTarget` plumbing rather than duplicating it.
- [ ] Unit test: constructing each kind yields the expected `signature` and `label`.

---

### Task 2: Signature scheme (widen the existing keys with team + roster)

- [ ] Define `ComposeTarget.signature` extending today's canonical keys:
  - note:   `note:<teamId|personal>`
  - chat:   `chat:<teamId|personal>[:c=<contactIds sorted, joined>][:g=<groupIds sorted>]`
  - twist:  `twist:<instanceId>`
  - channel:`<instanceId>|<channelId>|<linkType>`
  - dm/addr:`<instanceId>||<linkType>|<targets>[:c=<contactIds sorted>]`
  - The connector channel/dm forms must equal the existing `CreateTarget.key` for the no-roster case so existing `connectionMru` entries still match. Append the `:c=`/`:g=` suffix only when a roster is present.
- [ ] Add a helper to derive a signature from (a) a `CreateTarget` + roster, and (b) a recent thread (its primary link → instance/channel/linkType, or note/chat by absence of link; plus `teamId`, `contacts`, `groups`). Put it next to `CreateTarget.key`.
- [ ] Unit tests: round-trip — a `CreateTarget` with no roster produces a signature equal to its `.key`; with a roster, appends `:c=`; a recent-thread-derived signature matches the same combo.

---

### Task 3: Label rules (parentheticals)

- [ ] Implement `ComposeTarget.label`:
  - Connector targets: `"{Connector}"`, append ` ({account_label})` **only when the user has >1 connection for that connector**; append channel/contact detail (` · #general`, ` · Greg Smith`).
  - Note/Chat: `"Note"`/`"Chat"`, append ` ({Team name})` or ` (Personal)` **only when the user belongs to ≥1 team**.
  - Generalize the existing `_scopeSuffix` logic (connection_choice.dart) rather than reinventing it.
- [ ] Unit tests: >1-connection vs single-connection parenthetical; ≥1-team vs zero-team Note/Chat parenthetical.

---

### Task 4: Extend `LocalPreferencesBloc` MRU for global rank + richer keys

**File:** `apps/plot/lib/state/local_preferences.dart`.

- [ ] Add a **global** ranking path: a `rankSignaturesByMru({required List<String> signatures})` (priority-less) that orders by the existing global `lastUsedMs`, unseen last. (Keep `rankConnectionsByMru` for the per-priority focus suggestion Phase 5 uses.)
- [ ] Ensure `recordConnectionUsage` accepts the **full signature** (with roster/team), storing recency keyed by signature. Keep backward-compatible behavior for existing connector-only keys.
- [ ] Unit tests: global rank orders by most-recent global use; a signature with a roster records and ranks distinctly from the bare connector key.

---

### Task 5: `ComposeTargets` materialization + search

**File:** new `apps/plot/lib/state/compose_targets.dart` (a bloc/provider, following the codebase's bloc-composition pattern).

- [ ] **Base list** = dedupe-by-signature union of:
  1. **Used combos**: scan recent **authored** threads (reuse `actor.dart`'s authored-thread query, global/no-priority scope) → derive each thread's `ComposeTarget` signature → dedupe, most-recent-first.
  2. **Always-available templates**: `Note` + `Chat` for Personal and for each team the user belongs to; for each connection, one fresh compose template per its composable `linkType` (per `LinkTypeConfig.compose`); for channel connectors, surface recently-used channels (from the used-combos scan) — full channel lists are search-only.
  - Order: used combos in global-MRU order (Task 4) first; then templates not already represented.
- [ ] **Search(query)**:
  - Plain text → filter base list by `label`/`searchText`.
  - **Name match** → for each correspondent matching the text (limited to authored/replied via `actor.dart` banding so send-only addresses are excluded), synthesize the most-recent combos used with that contact across contact/DM/address-capable connectors — even if outside the base slice.
  - **Email input** (matches the email regex) → list every connection whose `linkType.compose.targets` is `addresses`/`contacts` (address-capable), ordering any previously used for *that address* first; include an "invite by email" affordance target.
- [ ] **Cache + incremental update**: materialize the base list once and cache it in the bloc state; recompute on inputs that change it (connections/channels, team membership). On thread creation, the existing record point calls `recordConnectionUsage(signature)` AND prepends/bumps that signature in the cached list so the next open reflects it immediately. (Wire the record call into the same submit path that currently records connection usage — but note the actual call site move is Phase 5; here, expose the method and update-cache logic.)
- [ ] Unit tests (bloc-level, mock stores): base list contains Note/Chat (Personal + per team) and per-connection templates; used combos rank ahead by recency; `search("stacy")` returns combos for a matching authored correspondent and excludes a send-only contact; `search("a@b.com")` returns address-capable connections; recording a new thread's signature prepends it to the cached list.

---

### Task 6: Verify

- [ ] `cd apps/plot && flutter analyze` clean on changed/new files.
- [ ] Run the new unit tests: `cd apps/plot && flutter test test/state/compose_targets_test.dart test/state/local_preferences_test.dart` (create these). If the worktree needs test bootstrap (`flutter pub get`, `build_runner build`, and copying `app.env` from the main repo per project memory), do it; if `app.env` is genuinely unavailable, report that the tests are written but couldn't run, and at minimum ensure `flutter analyze` passes.
- [ ] Do NOT change any compose UI, `new_thread.dart`, or the connection picker — Phase 5.

---

### Task 7: Commit

- [ ] `git add` the new + changed files and:
  ```
  git commit -m "feat(app): compose-target MRU substrate (ranked list + search)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" -- <paths>
  ```

## Out of scope
No `new_thread.dart` / `TargetPickerList` / picker UI (Phase 5). No removal of priority default-contacts. No DB changes.

## Acceptance
A cached, globally-MRU-ranked `List<ComposeTarget>` is available (Note/Chat per team + connector templates + recent combos), with `search()` synthesizing name/email targets filtered to authored/replied correspondents; recording a created thread's signature updates the cache; bloc unit tests pass (or are written + analyze-clean if the test runtime can't bootstrap); no UI changes.

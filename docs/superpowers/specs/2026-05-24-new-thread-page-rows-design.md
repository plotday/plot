# NewThreadPage row redesign

**Date:** 2026-05-24
**Owner:** kris@plot.day
**Scope:** `apps/plot/lib/page/new_thread.dart` and supporting widgets.

## Goal

Replace NewThreadPage's centered, mixed-direction "thread type selector"
with a consistent left-aligned vertical stack of four rows above the
NoteEditor:

1. Priority chip
2. Connection chips (new)
3. Contact chips, lock-led (private/share toggle absorbed into the row)
4. Title row (inline input replaces title modal)

The rows share a single left edge (the editor's left edge), share one
vertical-rhythm spacing constant, and each follows the same chip
anatomy used today for contacts. The redesign also replaces the
"create new connection item" entry point inside `LinkModal` for users
on NewThreadPage — they pick a connection directly via a chip.

## Non-goals

- No change to NoteEditor itself.
- No change to how a created thread is filed server-side beyond what
  already exists for `CreateLinkUserAction`.
- No multi-connection support — server only honors one
  `CreateLinkUserAction` per draft, so chips are single-select.
- No change to `LinkModal`'s own "Create new …" group; chip row and
  modal both surface the same targets and remain independently usable.
- No change to auto-organize semantics. The sparkles auto-toggle on
  the priority row keeps its current behavior.

## Layout

### Row stack

`_buildThreadTypeSelector` becomes a left-aligned `Column` with
`crossAxisAlignment: CrossAxisAlignment.start`, no `Center` wrappers,
no `WrapAlignment.center` inside rows. Rows are separated by a single
spacing constant (`context.theme.spacing.md`, currently 12px).

The single-panel and multi-panel branches of `build()` both consume
the same row stack. The `Padding(horizontal: context.contentPaddingH)`
on single-panel mode and the `Padding(horizontal: 20)` on multi-panel
mode stay, so the rows align with the editor on each.

The "auto-organize line" (`_buildAutoOrganizeLine`) currently
rendered *below* the priority/with rows and *above* the editor is
removed as a separate widget. Its title chip moves up into Row 4 of
the new stack.

### Vertical order

```
┌── editor content area ─────────────────────────┐
│ [sparkles?] [Priority]                          │  Row 1
│                                                 │
│ [GMail · thread] [Linear · issue] [Cal] [more]  │  Row 2
│                                                 │
│ [🔒] [Bob] [Alice] [+@user] [more]              │  Row 3
│                                                 │
│ [✨ Title]                                       │  Row 4
│                                                 │
│ ────────── NoteEditor ──────────                │
└─────────────────────────────────────────────────┘
```

When the user taps the title chip, Row 4 expands into a full-width
text input with the same prefix icon and a trailing `✕` clear button.

## Row 1 — Priority (unchanged behavior, left-aligned)

Logic in `_buildPriorityChipRow`, `_buildAutoSparklesToggle`,
`_buildPriorityChip`, `_selectPriority`, `_switchToAuto`,
`_switchToPriority`, `_applyChainDefaults` is unchanged.

Visual change only: remove the `Center` wrapper and `WrapAlignment.center`
from `_buildPriorityChipRow`. The leading sparkles auto-toggle (when
shown) sits to the left of the priority chip; both left-align with the
row.

Tooltips, keyboard shortcut (⌘⇧P / ⌥⌘⇧P on web), `auto` chip rendering,
and `ConstrainedBox(maxWidth: 240)` on the label are preserved.

## Row 2 — Connections (new)

### Source of truth

Hoist the existing `_CreateTarget` model and `_loadCreateTargets()`
function out of `apps/plot/lib/widget/link_input.dart` into a new
shared file: `apps/plot/lib/widget/connection_targets.dart`. Rename
`_CreateTarget` → `CreateTarget` (public). LinkModal imports the
shared symbol; the chip row imports the same. The criteria for a
connection appearing as a chip are identical to its appearance in
LinkModal's "Create new" group:

- Channel is enabled.
- Channel or twist has a link type with a status flagged
  `createDefault: true`.

Connections without a `createDefault` status are not chippable
(consistent with the existing "Create new" rule — some link types
cannot be created from Plot).

### MRU

A new `LocalPreferencesBloc` API records and ranks connection usage,
mirroring the per-priority MRU shape already used for contacts
(`Actor.getSortedShareCandidates(priority: ...)`):

```dart
// In LocalPreferencesBloc:
Future<void> recordConnectionUsage({
  required String channelKey,   // composite: "$twistInstanceId|$channelId|$linkType"
  required UuidValue priorityId,
});

Future<List<CreateTarget>> getSortedConnections({
  required Priority priority,
});
```

Storage shape: a `Map<channelKey, ConnectionUsageEntry>` where
`ConnectionUsageEntry` is `{lastUsedAt: DateTime,
priorityLastUsedAt: Map<UuidValue, DateTime>}`. Ranking:

1. Targets used in this priority, by `priorityLastUsedAt`
   descending.
2. Targets used cross-priority, by `lastUsedAt` descending.
3. Remaining enabled targets in deterministic order (twist name,
   then linkType label).

This matches how `Actor.getSortedShareCandidates` falls back from
priority-scoped MRU to cross-priority MRU.

`recordConnectionUsage` fires in `PriorityBloc.add` when the saved
thread carried a `CreateLinkUserAction`, keyed on
`(twistInstanceId, channelId, linkType)`.

### Chip anatomy

A `ConnectionChip` widget identical in shape to the contact chip:
24px border radius; `horizontal: 10`, `vertical: 10 (mobile) / 5
(desktop)` padding; `iconSizes.sm` prefix; `typography.sm` label.
Prefix is the connector logo (resolved via the same
`isDarkMode`-aware logic LinkModal uses today —
`logoDark ?? logo`). Label is `"$connectorName · $linkTypeLabel"`
with `linkTypeLabel.toLowerCase()` so it reads naturally
(e.g. "Gmail · thread", "Linear · issue"). Tooltip
(when the connection has an account suffix) shows the channel +
account: `"$channelName ($accountName)"`.

### Selection model (single-select)

A draft note carries at most one `CreateLinkUserAction` in
`note.actions`. The connection row reflects this:

- Tapping an inactive chip writes a `CreateLinkUserAction` for that
  target onto the draft note's `actions`, replacing any existing
  `CreateLinkUserAction` (other action types in the list are
  preserved).
- Tapping the active chip removes the `CreateLinkUserAction`.
- Chip variant: `primary` when active, `secondary` muted (`veryMuted`
  text + reduced logo opacity for inactive) when inactive. Same hover
  reveal as contact chips via `_HoverBuilder`.

The chip itself does not navigate or open any further picker — it
just toggles the draft state.

### Row composition

- Up to 3 chips, ordered by the MRU sort above.
- Trailing button: `more` if there are more than 3 targets total, or
  `add` if there are 3 or fewer (mirrors the `_buildAddContactChip`
  pattern).
- Tapping `more` opens a new `ConnectionPickerModal` (see below).
- If there are zero create-targets (no enabled connections that
  support creation), Row 2 is omitted entirely so users without
  integrations don't see an empty row.

### ConnectionPickerModal

A new modal in `apps/plot/lib/widget/connection_chip.dart` that
opens a `SelectModal<CreateTarget>` listing every create target,
grouped only by `"Create new"` (no recent links, no URL paste, no
existing-thread navigation — those stay in `LinkModal`). Picking a
target single-selects it on the draft. Reuses the same `ListTile`
rendering already in `LinkModal.itemBuilder` for the "Create new"
branch, so the modal entry rows look identical to LinkModal's.

## Row 3 — Contacts (lock-led)

Drop `_buildWithLabel` and the separate "Private / with" text row
entirely.

`_buildWithSelector` is modified to prepend a `_LockChip` as the
first item in the chips `Wrap`. The rest of the row
(`_pinnedGroups`, `_pinnedActors`, `_pinnedEmails`,
`_pinnedSuggestions`, `_buildAddContactChip`) is unchanged.

### Lock chip

- **Private** (no contacts/groups/emails after the existing
  self-exclusion filter — see `_buildWithSelector` line ~888): render
  as `primary` variant with a lock icon. Tap is a no-op (already
  private).
- **Shared** (any contacts/groups/emails present): render as
  `secondary` with `veryMuted` foreground and reduced lock icon
  opacity. Tap clears `draft.contacts`, `draft.groups`, and
  `draft.inviteEmails` in one `bloc.updateDraft` call, then calls
  `_refreshPinnedChips`. Pinned chips remain in the row but become
  unselected (matches existing chip-tap semantics) so the row layout
  doesn't jump.

### Privacy semantics

The same "exclude self linked contacts" rule used in
`_buildWithSelector` is applied when computing whether the draft is
private, so a stray self contact (inherited from priority defaults,
etc.) does not cause the lock chip to show as "shared."

Existing keyboard shortcut (⌘⇧S) for the share picker is unchanged.

## Row 4 — Title (inline input)

Replace `_buildAutoOrganizeLine`, `_buildTitleChip`,
`_buildClearTitleButton`, `_clearTitle`, `_openTitleModal`, and the
`_SaveDraftTitle` command with a new
`InlineTitleInput` stateful widget in
`apps/plot/lib/widget/inline_title_input.dart`.

### Collapsed state (chip)

Two sub-modes, mirroring today's chip behavior:

- **No title:** sparkles icon + "Title" label, `veryMuted` color. On
  hover, swap to pen icon + "Set title" label, `foreground` color.
- **Has title:** pen icon + actual title text, `muted` color on idle,
  `foreground` on hover. Title text is clipped with ellipsis and
  constrained to a sensible max width (e.g. 360px) so a long title
  doesn't push the row off-screen.

Tap → switch to expanded state.

### Expanded state (input)

- Container is the same chip shape (24px radius) widened to fill the
  row.
- Prefix icon: sparkles when the field is empty, pen when it has
  text. Recomputed live as the user types.
- Text field: `typography.sm`, single line, autofocused on expand,
  no visible border (inherits the chip container's border).
  `textInputAction: TextInputAction.done`.
- Suffix: `FButton.icon(close)` X button that *clears the input*,
  *clears `draft.title`*, *and* collapses back to the sparkles chip
  in one combined action.
- Pre-fills with the current `draft.title` on expand.

### Save / cancel

- **Enter** (`onSubmitted`): persists the current value (trimmed,
  empty → null) via `bloc.updateDraft`, then collapses to the
  appropriate chip state.
- **Blur** (focus loss without Enter, e.g. user clicks elsewhere):
  same as Enter — persist current value, collapse.
- **Esc**: revert any unsaved typing back to the last persisted
  `draft.title` and collapse without writing.

### Keyboard shortcut

The existing ⌘⇧H shortcut focuses the title input — expanding it if
collapsed — instead of opening the modal. No other handler changes.

## Cross-row interactions

- Changing priority via Row 1 triggers `_applyChainDefaults`, which
  may add/remove contacts/groups/emails in the draft. The lock chip
  in Row 3 recomputes from the new draft state on the next build, so
  switching to a priority with default shared contacts flips the
  lock from "private" to "shared." The connection chip row's MRU
  rerank is triggered by the same `_loadRecentCandidates` call path
  via a new `_loadRecentConnections()` helper.

- Submitting the thread (`_onChatSubmitted`) fires
  `recordConnectionUsage` for any active `CreateLinkUserAction` on
  the draft note, scoped to the priority the thread is being filed
  into. This is in addition to the existing `recordMentionUsage` call
  for the selected twist.

## Files

### Modified

- `apps/plot/lib/page/new_thread.dart` — primary rewrite. Drops:
  `_buildWithLabel`, `_buildAutoOrganizeLine`, `_buildTitleChip`,
  `_buildClearTitleButton`, `_clearTitle`, `_openTitleModal`,
  `_SaveDraftTitle`. Modifies: `_buildThreadTypeSelector`,
  `_buildPriorityChipRow`, `_buildWithSelector` (lock chip
  prepended), `build()` (removes `_buildAutoOrganizeLine` placements
  in both panel branches). Adds: `_buildConnectionRow`,
  `_loadRecentConnections`, `_pinnedConnections` field,
  `_activeCreateAction` getter, `_toggleConnection` handler,
  `_clearShareTargets` handler.

- `apps/plot/lib/widget/link_input.dart` — extract `_CreateTarget`
  and `_loadCreateTargets` to the new shared file. LinkModal
  re-imports them under the public name. Itembuilder for the
  "Create new" group becomes a small helper exported alongside, so
  the new connection picker modal uses the same rendering.

- `apps/plot/lib/state/local_preferences.dart` — adds
  `recordConnectionUsage` / `getSortedConnections` plus the storage
  shape (`Map<String, ConnectionUsageEntry>`). Persisted alongside
  existing local preferences.

- `apps/plot/lib/state/priority.dart` — in `PriorityBloc.add`, after
  stashing `ThreadsBase.pendingCreateLinks[...]`, also call
  `localPreferences.recordConnectionUsage(...)` for the chosen
  target. No other behavior change.

### New

- `apps/plot/lib/widget/connection_targets.dart` — `CreateTarget`
  model, `loadCreateTargets()` async loader, `createTargetTile()`
  list-tile builder shared with LinkModal.

- `apps/plot/lib/widget/connection_chip.dart` — `ConnectionChip`
  widget (chip rendering, hover, primary/secondary variants),
  `ConnectionPickerModal` (`SelectModal<CreateTarget>` wrapper).

- `apps/plot/lib/widget/inline_title_input.dart` —
  `InlineTitleInput` stateful widget implementing the
  chip ↔ input state machine.

## Test plan

The Flutter app does not have a strong widget-test surface for the
NewThreadPage today; verification is via `run-app`:

1. Open `Plot.app` (agent profile) on macOS.
2. From the root context, click **New thread**.
   - Verify four rows render left-aligned with even spacing.
   - Verify priority row shows the auto-sparkles toggle + an Auto
     chip when in root context.
3. Switch to a non-root priority via the picker.
   - Verify priority row updates and connection MRU rerank fires.
4. Connection row:
   - Tap an inactive connection chip → it goes primary; draft note
     gains a `CreateLinkUserAction`.
   - Tap a different connection chip → previous goes inactive, new
     one goes primary, draft note's action swaps.
   - Tap the active chip → it goes inactive, draft note loses the
     action.
   - Tap `more` → modal opens with all create-targets grouped under
     "Create new".
5. Contacts row:
   - With no contacts: lock chip shows primary. No "Private" text
     above row.
   - Tap a suggestion chip to add a contact: lock chip becomes
     secondary/muted, contact chip becomes primary.
   - Tap lock chip while shared: contacts cleared, lock chip
     returns to primary, contact chips stay pinned but unselected.
6. Title row:
   - Collapsed empty: sparkles + "Title" label visible.
   - Tap: collapses container expands to a text input, sparkles
     prefix, autofocused.
   - Type a title, press Enter: row collapses to pen + title chip;
     `draft.title` saved.
   - Tap again: input expands pre-filled, prefix is pen.
   - Press X: input clears, title clears, row collapses to
     sparkles + "Title".
   - ⌘⇧H from anywhere on the page: focuses (and expands if
     needed) the title input.
7. Submit thread:
   - With an active connection chip → server receives
     `pendingCreateLinks` payload as before.
   - Reopen New thread; verify the connection MRU placed that
     connection first in its priority.

## Risk and rollback

- **Behavior loss in LinkModal:** keep LinkModal's "Create new"
  group intact. The chip row is additive; users on existing
  workflows that pick "Create new" via the link picker still get
  the same result.
- **Connection chip without a logo:** the existing LinkModal already
  handles missing logos via `LogoImage(fallback: PlotIcon.add)`. The
  chip row uses the same fallback so a connection without a logo
  still renders.
- **Inline title focus thrash:** the inline input replaces a modal,
  so the keyboard focus story changes. Verify that opening the
  title input does not steal focus from the NoteEditor when the
  user is already typing (the input only expands on explicit tap or
  ⌘⇧H, so this should be inherent).
- **Rollback** is per-file: revert the changes in
  `new_thread.dart`, the new widget files, and the
  `local_preferences` / `priority` changes; the extracted
  `connection_targets.dart` can stay or be folded back into
  `link_input.dart`.

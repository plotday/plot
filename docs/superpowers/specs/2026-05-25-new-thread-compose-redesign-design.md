# NewThreadPage compose redesign

**Date:** 2026-05-25
**Owner:** kris@plot.day
**Scope:** `apps/plot/lib/page/new_thread.dart`, `apps/plot/lib/widget/inline_title_input.dart`, `apps/plot/lib/widget/connection_chip.dart`, plus new compose-field widgets under `apps/plot/lib/widget/compose/`.

## Goal

Redesign NewThreadPage to feel like a typical email compose window. Move the priority, connection, contacts, and title rows inside the same bordered surface as the note body, so the whole compose area reads as one connected form. Replace chip-style controls with text-field-style rows (icon + tooltip + value) that support fast keyboard entry on desktop and tap-to-modal on touch.

## Non-goals

- No change to NoteEditor body, attachments, or bottom action bar.
- No change to how a thread is filed server-side, or to the `CreateLinkUserAction` shape.
- No CC/BCC support in this pass — only the affordance for adding it later (chip-action menu).
- No multi-connection support — still single-select per draft.
- No new sync, RPC, or schema work.

## Layout

The four field rows sit inside the existing `EditableArea` border/background that today wraps only the note body. The compose surface becomes one bordered card with horizontal hairline dividers between field rows and between the last field row and the body.

```
┌───────────────────────────────────────────────┐
│ [📁]  Family                                  │  Priority
├───────────────────────────────────────────────┤
│ [🔗]  Plot thread                             │  Connection
├───────────────────────────────────────────────┤
│ [👤]  [Alice] [Bob] [bob@x.com]  ▏           │  Contacts
├───────────────────────────────────────────────┤
│ [✏️]  Q4 planning                              │  Title
├───────────────────────────────────────────────┤
│                                               │
│  Start a thread…                              │  Body (note editor)
│                                               │
│                                        [📎][▶]│  Bottom bar
└───────────────────────────────────────────────┘
```

**Field order is fixed** because each field's MRU ranking depends on the field above it:

1. **Priority** — drives the per-priority MRU for connection and contacts.
2. **Connection** — drives ranking inside the contacts dropdown when relevant.
3. **Contacts** — multi-value field of contacts, groups, and pending email invites.
4. **Title** — single-line subject.
5. **Body** — unchanged.

Both the single-panel and multi-panel branches of `NewThreadPage.build` consume the same compose surface. The existing horizontal padding behavior of each branch stays.

### Row chrome (`ComposeFieldRow`)

A new shared widget owns the row chrome:

- Leading icon, fixed width, sized to the field row.
- Tooltip on the icon shows the field label and, when a physical keyboard is available, the shortcut on a second line (reusing the existing `_buildChipTooltip` pattern in `new_thread.dart`).
- Slot for field content (text field, chip wrap, etc.).
- Hairline bottom divider in `context.theme.colors.border`.
- Tapping anywhere in the row (icon, empty space, or value) focuses the field's input.

Field icons:

| Field | Icon | Tooltip | Shortcut |
| --- | --- | --- | --- |
| Priority | `FontAwesomeIcons.folder` | Priority | ⌘⇧P (⌘⌥⇧P on web) |
| Connection | `PlotIcon.link` (`FontAwesomeIcons.link`) | Connection | — |
| Contacts | `FontAwesomeIcons.user` | Share with | ⌘⇧S |
| Title | `FontAwesomeIcons.pen` | Title | ⌘⇧H |

### Padding and spacing

Row content uses the same vertical rhythm as the current note editor's inner padding (`top: 8, bottom: 4` for the editor row already). Each row is roughly `40px` tall on desktop and `48px` on touch (taller hit targets, matching the `isMobilePlatform()` switch already in chip padding).

## Per-field behavior

### Priority

- **Value display:** the resolved priority label (`PriorityLabel`), or `✨ Auto` when the draft is in auto-file mode (drives off `ThreadsBase.autoFileIds` as today).
- **Desktop focus:** opens an inline `ComposeDropdown` anchored under the field. First item is `✨ Auto-organize` when the draft is not already auto-filed; remaining items are the user's priorities in `PriorityOrder.nested`. Arrow keys navigate; `Enter` selects; `Escape` closes; typing filters by `priority.matchesSearch(text)`.
- **Touch tap:** opens the existing `SelectModal<Priority>` (unchanged behavior — same `items`, `itemBuilder`, `onAdd`, and `filter` callbacks).
- **Side effects on change:** still calls `_switchToPriority` / `_switchToAuto`. These now invalidate the cached candidate lists feeding the contacts and connection dropdowns; the lists are recomputed lazily the next time those dropdowns open.
- The standalone `_buildAutoSparklesToggle` row disappears; auto-organize is reachable only through the priority dropdown / modal.

### Connection

- **Always has a value.** A new synthetic `CreateTarget` representing "Plot thread" is added to the in-memory list returned by `loadCreateTargets()` (wrapped, not modified at the source). This synthetic target's `toUserAction()` returns `null` so toggling it just clears any `CreateLinkUserAction` on the draft.
- **Value display:** the active target's `chipLabel`, or `Plot thread` when no `CreateLinkUserAction` is on the draft. The leading icon in the row is the field icon (`PlotIcon.link`); the active target's brand logo is **not** shown inline — it surfaces in the dropdown row only. (This keeps the row visually quiet and consistent with the other fields.)
- **Desktop focus:** opens the dropdown with all targets ranked by `LocalPreferencesBloc.rankConnectionsByMru` for the current priority, with "Plot thread" included in the ranking (it gets recorded on selection like any other target). Typing filters by `searchText`.
- **Touch tap:** opens `ConnectionPickerModal.open(context)`, extended to include the "Plot thread" target.
- The pinned-chips row (`_buildConnectionRow`) is removed. The ranking logic (`_rankConnections`, `_allConnectionTargets`, `_loadConnections`) stays but feeds the dropdown instead of a chip row; `_pinnedConnections` is dropped (the dropdown re-ranks on open).
- On selection, the existing `_toggleConnection(target)` runs; selecting "Plot thread" routes through the same code path and ends up with `actions` having no `CreateLinkUserAction`.

### Contacts

This is the most behavior-rich field. It's a hybrid chip-text input.

#### Visual

- Selected contacts, groups, and pending email invites render as compact chips inline, in this order:
  1. Groups (`FontAwesomeIcons.userGroup` prefix, group name)
  2. Contacts (small avatar prefix, contact name)
  3. Email invites (`FontAwesomeIcons.envelope` prefix, email)
- A trailing single-line text input with placeholder `Private — only you` when the chip list is empty, or empty placeholder when there are chips.
- All chips use a smaller compact style than the current `_buildContactChip` (no large prefix avatars; ~24px tall to match an inline text field).
- No suggestion chips are rendered inside the field. No lock chip.

#### Desktop keyboard

- Cursor sits at the end of the text input by default. Typing filters a dropdown of candidates (people, groups, and email-pattern matches against `_recentCandidates` and an on-demand fuller candidate list scoped to the current priority).
- `Enter` adds the highlighted dropdown item (or, if no dropdown item is highlighted and the input matches an email pattern, adds it as a pending email invite). `,` and `Tab` behave the same as `Enter` for email patterns when text matches `something@something.tld`.
- When the text input is **empty** and the chip list is non-empty:
  - `←` moves focus from the text input to the last chip; further `←`/`→` move focus across chips and wrap at ends.
  - `Backspace` or `Delete` on a focused chip removes it from the draft.
  - Any other character returns focus to the text input.
- `Escape` closes the dropdown (or returns chip focus to the text input).

#### Desktop mouse

- Hovering a chip shows the focused background.
- **Clicking a chip body** opens a `ComposeChipMenu` popover anchored to the chip with these items:
  - `Remove` (deletes the chip from the draft).
  - Placeholder: `Add as CC`, `Add as BCC` (rendered disabled now; live in a future change).
- The inline `×` button on contact chips goes away. Click-to-open-menu is the unified mouse affordance.

#### Touch

- Tapping anywhere in the row body (chip area or input) opens `PickDraftThreadShared` (the existing share modal), unchanged.
- Tapping an individual chip opens a small bottom-sheet `Modal` with the same options as the desktop popover (`Remove` now, CC/BCC later). This is a separate modal from `PickDraftThreadShared` to keep the per-chip action accessible without the user committing to the full picker.

#### Email parsing

- An input string matches the email pattern via a single regex (e.g. `^[^@\s]+@[^@\s]+\.[^@\s]+$`). Match → committable as a pending invite on `Enter`/`,`/`Tab`. No match → fall back to dropdown highlight as today.

#### Empty state

- No chips and empty input → placeholder text `Private — only you` in the input. This replaces the lock chip's role.

### Title

- Plain always-editable single-line `FTextField`. The `InlineTitleInput`'s chip / expand state goes away; the field is always in its "expanded" form.
- Placeholder `Title`. `onChanged` writes the new title to the draft via the same code path as today.
- `Enter` commits and moves focus to the body. `Escape` blurs.

## Component structure

New widgets under `apps/plot/lib/widget/compose/`:

- `compose_field_row.dart` — `ComposeFieldRow` (row chrome).
- `compose_dropdown.dart` — `ComposeDropdown<T>` (focus-driven dropdown using existing `Dropdown` + `OverlayPortal`, with arrow-key navigation and filter callback).
- `compose_chip_menu.dart` — `ComposeChipMenu` (desktop popover) and `ComposeChipMenuModal` (touch modal).
- `priority_compose_field.dart` — `PriorityComposeField`.
- `connection_compose_field.dart` — `ConnectionComposeField`.
- `contacts_compose_field.dart` — `ContactsComposeField` (chip+text hybrid).
- `title_compose_field.dart` — `TitleComposeField`.

`NewThreadPage` becomes substantially smaller. It still owns:

- Query-parameter draft initialization (`_initializeDraft`, `_applyQueryParametersToDraft`, `_resolveSharedUrlMetadata`).
- The `BlocBuilder` + `BlocListener` for `PriorityBloc`.
- The keyboard shortcut bindings (priority, share, title) and the legacy modal routes for touch.
- The composed `EditableArea` surface that wraps the four field widgets + the existing `Editor` body.

Wiring: the field widgets accept the current draft state plus callbacks. They do not read `PriorityBloc` themselves — `NewThreadPage` passes state and update callbacks down. This keeps the field widgets dumb and testable.

### NoteEditor changes

`NoteEditor` no longer owns the outer `EditableArea`. Instead, `NewThreadPage` mounts the `EditableArea` once and places the field widgets above the body. `NoteEditor` gains a flag (or a new `NoteEditor.bodyOnly` constructor) that skips the `EditableArea` wrapper when used inside the new compose surface. The thread page (`thread.dart`, the non-new-thread caller) keeps the current behavior with `EditableArea` inside `NoteEditor`.

### Focus model

Each field widget has its own `FocusNode`. The compose surface uses a `FocusTraversalGroup` with `OrderedTraversalPolicy` so Tab order is exactly Priority → Connection → Contacts → Title → Body. Reverse Tab (Shift+Tab) walks the same path backwards.

Mounting Order: On first mount, focus goes to the Body editor (current behavior on desktop via `autofocus`). All other fields receive focus only on user interaction (click, tap, keyboard shortcut, or Tab).

## Code removals

The following code in `apps/plot/lib/page/new_thread.dart` is deleted as part of the redesign:

- `_HoverBuilder` and all per-chip hover bookkeeping.
- Pinned-list state: `_pinnedActors`, `_pinnedEmails`, `_pinnedGroups`, `_pinnedSuggestions`, `_recentCandidates`.
- Pinned-list maintenance: `_loadRecentCandidates`, `_refreshPinnedChips`.
- Chip builders: `_buildPriorityChipRow`, `_buildPriorityChip`, `_buildAutoSparklesToggle`, `_buildConnectionRow`, `_buildWithSelector`, `_buildLockChip`, `_buildGroupChip`, `_buildContactChip`, `_buildEmailChip`, `_buildAddContactChip`.
- `_clearShareTargets` (no lock chip).
- `_ShareNewThread` and `_ConnectionPickerCommand` (command wrappers were chip-specific; replaced by direct callbacks).

The toggle helpers (`_toggleWithGroup`, `_toggleWithContact`, `_toggleEmailInvite`, `_toggleConnection`) move into the relevant compose field widgets or become small helpers in `NewThreadPage`. `_switchToAuto`, `_switchToPriority`, and `_applyChainDefaults` stay (driven from the priority dropdown / modal callbacks).

`InlineTitleInput` is replaced by `TitleComposeField` (the file is deleted; the only caller is `NewThreadPage`). `ConnectionChip` is kept (still used to render rows inside the connection dropdown) but the wrapper that builds the chip row is removed.

## Testing

Manual verification (run the app via the `run-app` skill):

- Desktop:
  - Tab through Priority → Connection → Contacts → Title → Body.
  - Open each field's dropdown by focusing or clicking; navigate with arrows; select with Enter.
  - Add and remove contacts with the keyboard: type → enter, then ← into chips, backspace.
  - Click a chip → popover with Remove appears; clicking Remove deletes the chip.
  - Add an email-format string and confirm it becomes a pending invite chip.
  - Confirm "Plot thread" is always the default connection value.
  - Switching priority re-ranks connection and contact dropdowns.
- Touch (iOS simulator):
  - Tap each field row → existing modal opens; soft keyboard does NOT appear for priority/connection/contacts.
  - Tap a chip → bottom-sheet modal with Remove option.
  - Tap title → soft keyboard opens for editing.

`flutter analyze` must pass with zero warnings in `apps/plot/lib/page/new_thread.dart` and the new widget files.

## Risks and open questions

- **Dropdown polish.** The new dropdown uses `OverlayPortal`-based `Dropdown`, which the codebase already uses elsewhere but not as a focused field dropdown. Positioning under the field across the four rows needs care so it doesn't get clipped by the editor border. Mitigation: dropdown opens above the field when there's not enough room below (use `LeaderLink`/`Follower` patterns already in `dropdown.dart`).
- **NoteEditor body-only mode.** Splitting `EditableArea` ownership between `NewThreadPage` and `NoteEditor` is a non-trivial refactor; the alternative is to leave `NoteEditor` owning `EditableArea` and stack the field rows visually on top with a shared border (no real shared container). The chosen approach (`NoteEditor.bodyOnly`) is preferred because it keeps the surface a single widget, but if the refactor balloons, the visual-only stacking is an acceptable fallback.
- **Performance.** Each field watching parts of the draft state could increase rebuild churn. `NewThreadPage` already restricts its `BlocBuilder.buildWhen` to `draft`/`draftNote`/`context` changes; the field widgets receive props from that single rebuild and do not subscribe independently.
- **Email parsing edge cases.** Plus-addressed emails, IDN domains, etc. The regex is intentionally lenient; ambiguous inputs fall back to non-email behavior (no chip created on Enter).

## Out of scope (future work)

- CC / BCC categories inside the contacts field. The chip-menu surface includes disabled placeholders today to anchor the future flow.
- A dedicated "schedule" field row (events still use the existing scheduler UI in the body).
- Keyboard shortcut for the connection field.

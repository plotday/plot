# Unread filter toggle — design

## Problem

In a priority's activity feed, unread items are interleaved with read items inside the Doing and Scheduled sections, and the New section sits below them. There is no way to see "everything unread in this priority" at a glance.

The existing layout is intentional: New items are kept below Doing so users can focus on regular work without being distracted by new arrivals. We do not want to change that default. We do want to give users a fast, optional way to switch into a triage view that shows only what's unread, then switch back.

## Solution

Add an unread-only filter toggle to the priority header. When active, the feed shows only threads in the priority's current unread set, preserving existing section grouping and order. The toggle button is rendered only when unread items exist; the filter auto-disables when the unread set drops to zero.

## Affordance

- **Location**: priority header, between the priority title and the Start timer / pomodoro pill, extending the existing trailing-widget row in `apps/plot/lib/widget/unified_header.dart`.
- **Visual**: plain icon button. Outline when inactive, filled when active (matches Plot's existing toggle treatments).
- **Icon**: the same unread/dot motif used by `ActivitySection.newSection` in the agenda. If no clean reuse exists, fall back to an envelope/mail glyph from the existing icon set.
- **Tooltip**: "Show unread only" when inactive, "Showing unread only" when active.
- **No badge, no count, no label**. The button's presence alone signals "you have unread"; the count lives in the New section as it does today.

## Visibility

The button renders if and only if the priority's feed contains ≥1 unread thread, using the same unread set that already drives `ActivitySection.newSection` membership. When the count drops to 0, the button disappears in the same frame the filter auto-disables.

## Filter behavior

When the filter is active:

- The feed shows only threads classified as unread (the same threads that contribute to the "has unread" signal above).
- Existing section grouping and order are preserved (Doing → Scheduled → New, with `eventAgenda` / `today` / `done` ordering unchanged where applicable).
- A section header renders only if its filtered view has ≥1 item.
- All other UI — priority header, pomodoro pill, agenda actions, drag/drop, keyboard navigation — is unchanged.

When the filter is inactive, the feed renders exactly as it does today.

## Read-while-filtering

A thread that gets read while the filter is active stays visible in the filtered list until the user navigates away from the thread. The feed recomputes membership when the user returns to the priority view, not on per-thread read-state changes.

This reuses the existing "sticky unread" mechanism already used by `ActivitySection.newSection` rather than introducing a separate snapshot.

## Auto-off

When the underlying unread set reaches 0 after a feed recompute (e.g. user navigates away and back; all items have since been read), the filter turns itself off and the button hides in the same frame. This avoids the "filter on but feed is empty" dead state.

## State scope

- Per-priority, in-memory only.
- Switching priorities resets the filter to off.
- Not persisted across app restarts.

Rationale: this is a triage-mode toggle, not a user preference. Carrying it across priorities or sessions would surprise users who expect each priority to open in its normal layout.

## Keyboard shortcut

- `⌘⇧U` on macOS, `Ctrl+Shift+U` on Windows/Linux.
- Implemented via `platformSingleActivator(LogicalKeyboardKey.keyU, shift: true)` (the established Plot pattern used by `Shift+T`, `Shift+D`, `Shift+I`).
- The Cmd/Ctrl modifier ensures the shortcut intercepts above the NoteEditor and works regardless of editor focus.
- Active only when a priority feed is the focused view; suppressed inside modals (same as existing command shortcuts).
- No-op when zero unread exist (matches button-hidden state).

## Code structure

- **Command**: new `ToggleUnreadFilter` in `apps/plot/lib/command/`, per the project convention that every user action is a command.
- **State**: held on the priority Bloc (`apps/plot/lib/state/priority.dart` / `priority_state.dart`), exposed as a `bool unreadFilterActive` and a derived `bool hasUnread` selector.
- **Feed filtering**: applied in the activity-section builder where unread classification is already computed (see `apps/plot/lib/state/activity_section.dart` and the priority feed builder), reusing existing logic — no new unread computation.
- **Header button**: rendered in `apps/plot/lib/widget/unified_header.dart` next to the Start timer button, gated on `hasUnread`. Bound to `ToggleUnreadFilter` so it inherits the shortcut.

## Out of scope

- Count badge on the button.
- Persistence across sessions or priorities.
- Changes to section order, the New section's behavior, or how unread state is computed.
- "Unread within Doing" mini-sections, jump-to-next-unread, or any other layout changes (approaches B and C from the brainstorm).
- Filtering across multiple priorities or a global "all unread" view.

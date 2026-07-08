# Sidebar private-note shortcut — design

## Summary

Add a hover-revealed icon button to each focus row in the sidebar, positioned
immediately to the left of the existing "More" (⋯) button. Clicking it opens
the New Thread compose flow with that focus pre-selected as a private-note
target — identical to manually clicking that focus under the "Private note"
section on the New Thread page.

## Behavior

- The button is visible only on hover of a focus row (same visibility rule as
  the existing More button).
- Icon: `PlotIcon.note` (`FontAwesomeIcons.note`) — deliberately distinct from
  `PlotIcon.addNote` (`FontAwesomeIcons.penToSquare`), which is already used
  by the generic "New thread" command, so the two shortcuts read as visually
  different actions.
- Tooltip/command title: "Add private note".
- Clicking it:
  - Opens/reuses the New Thread compose page.
  - Skips step 1 (the sections picker) and lands directly in compose, as if
    the user had picked that focus under "Private note".
  - Clears any selected recipient/roster (`_selectedRecipient = null`,
    contacts/groups/invite emails cleared) — a private note has no audience.
  - Focuses the note editor.
  - Does **not** change the sidebar's currently-displayed focus/PriorityRoute.
    Composing is Activity-tab-scoped, not tied to which focus's route happens
    to host the nested `NewThreadRoute` — the same way "New thread" and "Help
    & Feedback" work today.
  - If a compose is already in progress (any target), it is replaced by the
    private-note target for the clicked focus — the same behavior as manually
    switching targets in the picker, and the same behavior Help & Feedback
    already has when reused on a live page.

## Scope

- Applies to every real `Priority` row rendered via `PriorityWidget` in
  `widget/priority.dart` (used for every focus, including Inbox).
- Does **not** apply to the "Everything" entry, which renders via the
  separate `FixedFocusTile` widget and has no single `priorityId` to target —
  there is no valid private-note target for it.

## Implementation approach

This mirrors the existing "Help & Feedback" mechanism
(`NewThreadPageState.feedbackRequest` / `widget.feedback` /
`PrioritiesShell._openFeedbackThread`), parameterized by which focus was
clicked instead of a hardcoded Inbox target. That mechanism exists because:

- `NewThreadPageState` holds all compose-flow state (`_step`,
  `_selectedTarget`, in-progress draft) and AutoRoute reuses the already
  mounted instance rather than remounting it on navigation.
- A plain `navigate(PriorityRoute(children: [NewThreadRoute(...)]))` silently
  drops the nested `NewThreadRoute` child whenever the parent `PriorityRoute`
  is already on the stack — so reconfiguring a live page requires a
  side-channel signal, and reaching a fresh/cold-start page requires a route
  query param.

Concretely:

1. **Sidebar button** (`apps/plot/lib/widget/priority.dart`): add
   `Button.icon(NewPrivateNote(priority))` before the existing
   `Button.icon(ShowPriorityCommands(priority))` in the row's
   `trailingBuilder`, so it only shows on hover, matching More.

2. **New command** (`apps/plot/lib/command/priority.dart`):
   `NewPrivateNote extends Command`, icon `PlotIcon.note`, title
   "Add private note". `run()` returns a new `CommandRoute` subclass
   (`OpenPrivateNoteThread`, mirroring `OpenFeedbackThread`) whose `go()`
   calls a new `PrioritiesShell.openPrivateNote(context, priorityIdString)`.

3. **Shell navigation** (`apps/plot/lib/widget/priorities_shell.dart`): new
   `_openPrivateNote(context, priorityIdString)`, mirroring
   `_openFeedbackThread`:
   - Live inner router found → call `NewThreadPageState.requestNote(priorityId)`
     to reconfigure the already-mounted page; push `NewThreadRoute(notePriorityId: ...)`
     only if not already on `NewThreadRoute`.
   - No inner router yet (cold start) → navigate to
     `PriorityRoute(priorityIdString: priorityIdString)` (seeded with the
     *clicked* focus, unlike feedback's fixed Inbox seed) and push
     `NewThreadRoute(notePriorityId: priorityIdString)` once the inner router
     appears, via an extended `_pushNewThreadWhenInnerReady` that also
     accepts `notePriorityId`.

4. **Page-level handling** (`apps/plot/lib/page/new_thread.dart`):
   - New `@QueryParam('notePriorityId') this.notePriorityId` on
     `NewThreadPage`.
   - New static `ValueNotifier<int> noteRequest`, `_pendingNotePriorityId`,
     and `requestNote(Uuid priorityId)`, mirroring `feedbackRequest` /
     `_pendingForward`.
   - New instance method `_applyPrivateNoteMode(Uuid priorityId)`: resolves
     the `Priority`, builds
     `ComposeTarget.focusNote(priorityId: ..., teamId: ..., title: ...)`,
     clears `_selectedRecipient`, calls `_applyTarget(target)` — the same
     path `_applyDirectTarget` takes when a focus is picked manually under
     "Private note".
   - Wiring: `_lastNoteSeen` instance field +
     `noteRequest.addListener(_onNoteRequested)` /
     `removeListener` in `initState` / `dispose` (mirrors
     `_onFeedbackRequested`), plus a fresh-mount branch in
     `_initializeDraft` reacting to `widget.notePriorityId` (mirrors the
     `widget.feedback` branch).

## Testing

- Widget test on the sidebar row: the new button is absent when not hovered
  and present (with correct tooltip) when hovered, alongside the existing
  More button.
- Widget/unit coverage on the command/navigation path: invoking
  `NewPrivateNote` for a given priority results in the New Thread page
  showing compose step with that priority as the target and no roster —
  covering both the fresh-mount (query param) and live-page (signal) paths,
  matching how the existing feedback-mode tests (if any) are structured.

## Out of scope

- No changes to `FixedFocusTile` / the "Everything" sidebar entry.
- No changes to the New Thread page's manual "Private note" picker section
  itself — this only adds a second entry point into the same existing flow.

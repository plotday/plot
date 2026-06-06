# NewThreadPage active/inactive styling

## Goal

Reduce how much the new-thread compose panel catches the eye when it isn't in
active use. Style two visual modes with an animated colour-fade transition
between them:

- **Active** — current full-strength appearance.
- **Inactive** — everything muted by one step, including the (SVG) connector
  logos.

## Behaviour

A single computed boolean drives the visual state:

```
active = singlePanel        // !layoutState.multiPanel — single-panel is always active
      || _mouseInside       // pointer is over the panel
      || _pageFocused       // any descendant (filter, editor, fields) holds keyboard focus
      || _filterHasText     // step-1/2 filter controller is non-empty
      || _newThreadPulse    // momentary: set when NewThread opens/resets the page
```

- **Single panel** mode is always active (no dimming on mobile / narrow
  layouts).
- **Keyboard navigation** is covered implicitly: navigating with the keyboard
  means a page descendant holds focus, so `_pageFocused` is true.
- **`_newThreadPulse`** bridges the gap between the New-thread button press and
  focus actually landing, and covers ⌘N when no autofocus fires. It is cleared
  on the first pointer-exit **or** focus-loss, so it never lingers ("also dim on
  focus loss").
- Default deactivation is pointer-exit; focus-loss and an empty filter also pull
  the state toward inactive once nothing else holds it active.

## Rendering

Wrap the Scaffold `body` (the `LayoutBuilder` at `new_thread.dart:1636`) in three
layers, outermost first:

1. **`MouseRegion`** — `onEnter` sets `_mouseInside = true`; `onExit` sets it
   false and clears the pulse.
2. **`Focus`** (`canRequestFocus: false`, `skipTraversal: true`) —
   `onFocusChange(hasFocus)` updates `_pageFocused` and clears the pulse on
   focus-loss. Tracks descendant focus without joining traversal.
3. **`AnimatedOpacity`** — `opacity: active ? 1.0 : kNewThreadInactiveOpacity`
   (~`0.55`, tunable constant), `duration: ~250ms`, `curve: Curves.easeOut`.
   Because it wraps only the content (the translucent Scaffold panel background
   sits outside it), text, icons, accents, and the SVG connector logos all mute
   together by the one opacity step.

## Performance — avoid editor flicker

Hover/focus changes must **not** call `setState`, or the whole `BlocBuilder`
subtree (including `NoteEditor`) rebuilds on every mouse enter/exit — the known
flicker trap in this page.

- A `ValueNotifier<bool> _active`. The `MouseRegion` / `Focus` / filter-listener
  callbacks update the input fields and call `_recomputeActive()`, which only
  sets `_active.value`.
- A `ValueListenableBuilder<bool>` wraps the `AnimatedOpacity`, passing the
  already-built body as its `child` so the body subtree is never rebuilt when
  `active` flips — only the opacity layer re-evaluates.

## Wiring details

- **Filter text**: add a listener on the page-owned `_pickerSearchController`
  (`new_thread.dart:173`) that recomputes when emptiness changes.
- **Pulse**: set true in `initState` (fresh mount = the button opened it) and in
  `_onResetRequested` (live-reuse reset).
- **Single panel**: store `layoutState.multiPanel` from the build's `LayoutBloc`
  builder and recompute on change.
- **Dispose**: remove the controller listener and dispose `_active`.
- **Tuning**: `kNewThreadInactiveOpacity` constant at file top so the dim step is
  easy to dial during run-app verification.

## Scope

Single file: `apps/plot/lib/page/new_thread.dart`. No new widgets, no
theme/token changes, no logo changes (opacity handles them). Do not `dart format`
(repo uses the old short style).

## Verification

- `flutter analyze` clean on the changed file.
- run-app: confirm the panel starts inactive in multi-panel mode, fades to
  active on hover / typing / ⌘N / keyboard nav, and fades back to inactive when
  the pointer leaves and focus is dropped; confirm single-panel mode never dims.

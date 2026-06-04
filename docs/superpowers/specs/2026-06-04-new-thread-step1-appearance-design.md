# New-thread step 1 — appearance redesign

**Date:** 2026-06-04
**Status:** Implemented (scope grew during live review — see Addendum)
**Area:** Flutter app — `NewThreadPage` step 1 (the inline target picker)

> **Addendum — shipped scope.** During live review the change grew beyond the
> original appearance spec below. As shipped it also includes:
>
> - **Avatar polish:** people-row avatar 18→20 (the 1.2px ring made 18 read
>   shorter than the 16px logo); gap to the label `xs`→`sm`.
> - **Highlight match:** the row hover/selection fill uses
>   `ColourScheme.editableBackground` (the activity feed's `highlightColor`),
>   not the heavier `colors.secondary` tint.
> - **Escape on step 2 → go back:** Escape now performs the same "go back to
>   step 1" as tapping the Connection field (`_handleEditorKeys` for the body
>   editor; a step-2-only `SingleActivator(escape)` for the other fields).
> - **Filter input fill:** forced transparent in *every* state (the global
>   text-field delta filled it with `editableBackground` on focus).
> - **Chat/Note unification:** the Plot Note/Chat distinction is removed.
>   `PlotThreadKind`/`plotNote`/`plotChat`/`plotForKind` are gone; a single
>   `PlotThreadChoice` carries the team scope so the connection field shows
>   **"Plot"** (+ team when the user belongs to ≥1 team). The contacts field is
>   **always** shown for Plot threads (including focus-note starts). The body
>   placeholder ("Start a chat"/"Add a note") and Send/Save label stay adaptive
>   on whether recipients are present — they were never a stored mode. The
>   internal `ComposeTargetKind` enum and MRU signatures are unchanged (no
>   preference-history migration).

## Goal

Step 1 of the new-thread compose flow is one of the first surfaces new users
see. It must convey the calm, premium brand and feel cohesive with the rest of
the app. The current surface has four problems:

1. The filter input reads as a constrained form field (full boxed outline).
2. The list rows are too tight to distinguish from one another.
3. The list has no scroll-edge fade.
4. The list is capped partway down the page instead of extending to the bottom.

Additionally, the step-2 Connection field currently re-opens the picker inside a
**modal** with different (compact) styling — the only consumer of the picker's
`inline: false` look. Re-using a divergent modal style undercuts the cohesion
goal, so step 2's "change connection" becomes a plain **go-back** to step 1.

## Scope

- **In scope:** the *inline* `TargetPickerList` (`apps/plot/lib/widget/compose/target_picker_list.dart`)
  and the step-1 layout in `apps/plot/lib/page/new_thread.dart`.
- **Out of scope:** step-2 compose surface layout, the editor, the priority /
  contacts pickers, mobile-specific behavior beyond what already gates on
  `hasPhysicalKeyboard()`.

## Design

### A. Filter input — fading underline

Replace the boxed `FTextField` outline (inline path) with a borderless field
plus a custom fading underline.

- No border in any state (`InputBorder.none` / transparent border via the
  existing `FTextFieldStyleDelta` override).
- Text sized **`typography.lg` (18px desktop / 20px mobile)** — a calm step above
  the rows (`md`, 15px) and the app header search (`md`, 15px). Hint text in
  `colors.mutedForeground`.
- Generous vertical content padding so the field feels open, not boxed.
- **Underline:** a ~1.5px-tall element beneath the field painted with a
  horizontal `LinearGradient`:
  `transparent → colors.border → colors.border → transparent`, stops roughly
  `[0.0, 0.18, 0.82, 1.0]`, so it glows in the middle and dissolves into the
  page background at both ends. Drawn as a sibling under the field (Column /
  Stack), not as an input border.
- **Focus:** the underline brightens slightly on focus (raise the mid-stop
  alpha, e.g. `border` → a stronger neutral). It stays **neutral** — no accent
  tint — consistent with the current deliberate choice ("tweak 3").
- **Behavior preserved exactly:** autofocus on physical keyboards only
  (`autofocusSearch && hasPhysicalKeyboard()`), `onTapOutside` no-op (stray
  clicks keep focus), Escape clears the filter when non-empty / propagates when
  empty (`_onSearchFieldKey` — **unchanged**), trailing clear `✕` (still laid
  out always, faded/disabled when empty), Enter-to-select (`onSubmit`).

### B. Row density — comfortable

In the (now sole) styled path:

- Row content vertical padding: `spacing.xs (2)` → **`spacing.md (10)`**.
- Inter-row gap (`_rowDecoration` bottom margin): `spacing.xs (2)` →
  **`spacing.sm (6)`**.
- The synthetic "Add a connection…" row uses the same vertical padding so it
  lines up with the target rows.
- Update `_estimatedItemHeight` from `62.0` to match the taller row so the
  keyboard scroll-into-view math stays accurate (over-estimate is safe).

### C. Scroll edge fade

- Wrap the list (`Flexible` → `ListView.builder`) in the existing
  `ScrollEdgeFade` widget in **`transparent: true`** (alpha-mask) mode — the
  page sits on the translucent / tinted scaffold frame, so a solid-background
  fade would read as a card. Top edge fades once scrolled away from the top;
  bottom edge fades while more rows remain below.

### D. List extends to the bottom

In `_buildTargetPickerStep`, multi-panel branch:

- Drop the `constraints.maxHeight * 0.25` top spacer + `constraints.maxHeight *
  0.6` height cap.
- Replace with a **comfortable fixed top inset** (tuned in-app; ~48px starting
  point) above the picker, then let the picker fill the remaining height **down
  to the bottom edge** (where the fade lives).
- Single-panel branch already fills to the bottom; it only gains the fade via C.
- Scoped to step 1; the step-2 multi-panel centered layout (`build`) is
  untouched.

### E. Connection field = "go back" (replaces the modal)

The step-2 Connection field stops opening a modal and instead navigates back to
step 1.

- **Replace `_openConnectionPicker()`** with a `_returnToTargetStep()` handler
  wired to `ConnectionComposeField`'s activation callback (the `openModal`
  parameter — kept as-is to avoid churn across the sibling compose fields; only
  its bound closure changes):
  - `setState(() => _step = _ComposeStep.target)`.
  - Fire-and-forget `ComposeTargetsBloc.refresh()` to re-rank the base list
    (matches `_resetToFreshStart`); cheap and the list is already populated, so
    rows show immediately.
  - Post-frame, on physical-keyboard platforms only: focus
    `_pickerSearchFocusNode` and **select all** of the restored filter text
    (`_pickerSearchController.selection = TextSelection(baseOffset: 0,
    extentOffset: text.length)`) so typing replaces it.
- **Restore prior state — hoist the search controller to the page.** Add a
  page-owned `TextEditingController _pickerSearchController` (disposed in
  `dispose`), passed to the inline `TargetPickerList` via its existing
  `searchController` parameter (alongside the already-hoisted
  `searchFocusNode`). The filter text now survives the
  step-1 → step-2 → step-1 round-trip. `_resetToFreshStart` clears it so a fresh
  new-thread starts empty.
- **Picker filters on mount when pre-filled.** In `_TargetPickerListState`,
  after seeding `_results` from the bloc, if `_controller.text.trim()` is
  non-empty, run a search so restored filter text shows filtered results
  immediately instead of the unfiltered base list.
- **Draft carries over for free.** A new selection routes through the existing
  `_applyTarget()`, which rewrites only the connection action + roster + team
  and never touches the note body or title. Selecting the *same* connection
  simply re-applies and returns to step 2 (back-then-forward). There is no
  separate cancel path by design.

### F. Collapse the picker to one styled path

With the modal gone, `inline: false` has no remaining consumer. Remove the
modal-specific branches and simplify:

- Remove the modal branch of `_buildSearchField` (the ghost `TextField`).
- Remove the `inline` parameter and resolve **every** `widget.inline` reference
  to its inline-true behavior, specifically:
  - `_buildSearchField`: keep only the inline (fading-underline) field.
  - `_buildList`: the `if (widget.inline) SizedBox(height: lg)` gap before the
    first row becomes unconditional.
  - `_rowDecoration`: keep only the rounded-fill + bottom-margin branch (drop
    the flat modal branch).
  - `_rowContent` and `_buildAddConnectionRow`: the `widget.inline ? … : …`
    padding ternaries collapse to the inline value (`spacing.md` per B).
- Keep the remaining parameters: `autofocusSearch`, `scrollController`,
  `listFocusNode`, `searchController`, `searchFocusNode`, `onSelect`.
- Remove the now-unused `import 'package:flutter/material.dart' show
  OutlineInputBorder;` if the borderless approach no longer needs it (or keep
  the `show` import if the underline implementation still references material
  border types).

## Components touched

| File | Change |
|------|--------|
| `apps/plot/lib/widget/compose/target_picker_list.dart` | A (input), B (density), C (fade), F (collapse to one path); filter-on-mount when pre-filled |
| `apps/plot/lib/page/new_thread.dart` | D (layout to bottom), E (go-back handler + hoisted search controller + clear on reset) |

No schema, store, bloc-API, or data changes. `ComposeTargetsBloc` is unchanged.

## Values tuned in-app (run-app screenshots, not guessed)

- Underline resting alpha and focus-brightened alpha.
- `ScrollEdgeFade` fade extent (default 16px) — keep or adjust for this list.
- Top inset above the input in multi-panel mode (~48px starting point).
- Final row vertical padding / gap if `md`/`sm` reads off once rendered.

## Verification

- `flutter analyze` clean on changed files (full-app analyze not required — no
  non-nullable column / constructor changes).
- Manual, via the `run-app` skill on macOS:
  1. Open a new thread → step 1 shows the fading-underline input, comfortable
     rows, list running to a faded bottom edge.
  2. Scroll the list → top fade appears; bottom fade hides at the end.
  3. Type a filter → rows filter; clear `✕` and Escape behave as before.
  4. Pick a target → step 2; tap the Connection field → returns to step 1 with
     the prior filter text restored and selected; pick a different connection →
     step 2 with the previously-typed note body/title intact.
- Confirm the step-2 modal no longer appears anywhere (the only modal user is
  removed).

## Out of scope / follow-ups

- No change to step-2 field order or the editor.
- No change to MRU ranking, search semantics, or the add-connection action.

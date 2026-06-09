# Suggested focuses in the focus-creation flow

**Date:** 2026-06-09
**Status:** Design approved, pending spec review

## Problem

The suggested focuses (Project, Customers, Operations, Management, Recruiting,
Admin, Reading, Volunteering, Personal admin, Social, Promotions) used to be
surfaced as chips in onboarding's "Focus on what matters" step. Those chips have
since been removed, so the curated suggestions are now dead code (`kSampleFocuses`
+ `OnboardingRoles` widget in
`apps/plot/lib/widget/onboarding/onboarding_roles.dart`).

We want to bring the suggestions back, but as part of the **regular** focus
creation flow rather than onboarding-only. When the user triggers "Add a focus",
they should see a modal offering a custom focus plus the curated suggestions;
picking a suggestion prefills the create form. Suggestions a user has already
acted on should stop appearing — including across their devices.

## Goals

- Surface curated focus suggestions everywhere "Add a focus" is triggered.
- Picking a suggestion prefills (but does not auto-create) a focus.
- Once a focus is **created** from a suggestion, that suggestion is hidden from
  the picker, on every device the user signs in to.
- One unified focus-creation path (onboarding now reuses the sidebar button).

## Non-goals

- No change to the two-step focus-creation form itself (name/icon/color/
  description + thread-matching). Suggestions reuse it as-is.
- No re-introduction of onboarding chips.
- No backfill: dismissals are recorded going forward only.

## User-facing behavior

Triggering **"Add a focus"** (from any entry point) opens a picker modal:

1. **"Create a custom focus"** — top row, no section header. Opens the existing
   `NewFocus()` two-step form, empty.
2. **"Suggestions"** — a section listing each *non-dismissed* suggestion. Each row
   shows the suggestion's focus icon, its **title**, and its **description** (as
   the row subtitle). Selecting a row opens the same `NewFocus` two-step form with
   all fields prefilled from the suggestion.

Selecting any row opens the create modal nested above the picker (standard
`command.run(context)` nesting), so Back/Esc returns to the picker.

**All-dismissed shortcut:** if the user has already dismissed every suggestion,
"Add a focus" skips the picker entirely and opens `NewFocus()` directly (the
picker would otherwise show only "Create a custom focus", which is redundant).

A suggestion is **dismissed only when a focus is actually created** from it
(either branch of the two-step form: skip-matching create, or create-with-
matched-threads). Cancelling the form records nothing.

## Architecture

### Suggestion data — single source of truth

- Move the suggestion list out of the dead `onboarding_roles.dart` into a new
  dedicated, maintenance-friendly file `apps/plot/lib/command/focus_suggestions.dart`,
  exposed as `const List<FocusPrefill> kFocusSuggestions`. A standalone data file
  (rather than burying it in the already-large `priority.dart`) makes the list
  easy to grow and prune over time, which is an explicit goal.
- Add `suggestionKey` (`String?`) to `FocusPrefill` (its definition stays in
  `priority.dart`; the suggestions file imports it). Each suggestion sets an
  **explicit, stable** key. The key — not the title or list position — drives
  dismissal, so titles/descriptions/order can be edited freely and items can be
  added or removed without disturbing existing users' dismissals.

  Initial keys:

  | Title | key |
  |---|---|
  | Project | `project` |
  | Customers | `customers` |
  | Operations | `operations` |
  | Management | `management` |
  | Recruiting | `recruiting` |
  | Admin | `admin` |
  | Reading | `reading` |
  | Volunteering | `volunteering` |
  | Personal admin | `personal_admin` |
  | Social | `social` |
  | Promotions | `promotions` |

- The custom/empty path leaves `suggestionKey` null.
- Delete the now-unused `OnboardingRoles` widget, `_SampleFocusChip`, the
  `onboarding_roles.dart` file, and its dead import in `onboarding_steps.dart`.

Each suggestion entry is a `FocusPrefill` with `suggestionKey`, `title`,
`description`, `iconKey`, and optional `color` (the existing fields).

**Maintaining the list over time:**
- *Adding* an item: append a new entry with a fresh unique key. It appears for
  every user who hasn't dismissed that key (i.e. everyone, since the key is new).
- *Removing* an item: delete the entry. Any stored dismissal of its key becomes a
  harmless orphan — filtering ignores keys with no matching suggestion (see Edge
  cases). No migration needed.
- Keys must be unique and never reused for a different concept (a reused key
  would inherit the old item's dismissals).

### The picker — new `AddFocus` command (`ShowCommands`)

`AddFocus extends Command` (not a static `ShowCommands`, because it must load the
dismissed set before deciding whether to show the picker at all):

```
run(context):
  dismissed = await DismissedFocusSuggestions.get()      // Set<String>
  remaining = kFocusSuggestions.where((s) => !dismissed.contains(s.key))
  if (remaining.isEmpty) return NewFocus().run(context)   // shortcut
  return ShowCommands(
    title: 'Add a focus',
    commands: Commands(groups: [
      StaticCommandGroup(commands: [ _CreateCustomFocus() ]),       // no header
      StaticCommandGroup(title: 'Suggestions',
        commands: [ for (s in remaining) _CreateSuggestedFocus(s) ]),
    ]),
  ).run(context)
```

- `_CreateCustomFocus` — lightweight command, title "Create a custom focus",
  `PlotIcon.add`; `run()` → `NewFocus().run(context)`.
- `_CreateSuggestedFocus(suggestion)` — title = suggestion title, subtitle =
  suggestion description, icon = `PlotIcon.focusIcon(suggestion.iconKey)`;
  `run()` → `NewFocus(prefill: suggestion).run(context)`.

`AddFocus` replaces the focus-creation trigger at all three entry points:

| Entry point | File | Current | New |
|---|---|---|---|
| Sidebar "Add a focus" button | `lib/widget/priorities_list.dart` (~118) | `NewFocus()` | `AddFocus()` |
| Global command palette | `lib/command/global.dart` (~102) | `NewFocus()` | `AddFocus()` |
| Focus switcher secondary (Cmd+J) | `lib/command/priority.dart` (~236) | `NewPriority(parent:)` | `AddFocus()` |

### Recording dismissal (only on save)

The two-step create form's `FormButton`s build either `AddPriority` (skip-matching
branch) or `_CreateFocusWithThreads` (matching branch). Both already run a
`save()`. Thread the suggestion key through:

- `_buildFocusDetailsForm` / `_buildFocusMatchesForm` already receive `prefill`
  (details form) — capture `prefill?.suggestionKey` and pass it into the create
  commands. (`_FindMatchingThreads` → `_ShowFocusMatches` → `_CreateFocusWithThreads`
  must also carry the key through, since the matching branch loses `prefill`
  otherwise.)
- Add an optional `String? suggestionKey` to `AddPriority` and
  `_CreateFocusWithThreads`. After a successful `save()`, if non-null, call
  `DismissedFocusSuggestions.add(key)`.

`DismissedFocusSuggestions` is a small helper over `UserSettingsEntity`:

```
get()        -> Set<String>   (reads dismissed_focus_suggestions, [] if none)
add(key)     -> read-modify-write the list (dedup), UserSettingsEntity.save(...)
```

### Cross-device storage

New synced column on `user_settings`: `dismissed_focus_suggestions`, a jsonb
array of suggestion keys, default `'[]'`, nullable (partial-update convention).
Mirrors the existing List-converter columns (e.g. `thread.contacts` uses
`UuidListConverter`; here a string-list equivalent).

**Server (`libs/db/schema`):**
- Add `"dismissed_focus_suggestions" jsonb DEFAULT '[]'::jsonb` to
  `libs/db/schema/50-tables/99-user-settings.sql` (nullable per the table's
  "all fields added below must be nullable" rule — keep the column nullable and
  let the converter treat null as empty).
- `pnpm gen-migration -- add_dismissed_focus_suggestions`
- `pnpm apply-migrations` (regenerates `libs/db/src/types.ts`; commit it)
- `pnpm diff-schema-migrations` and `pnpm --filter @plotday/db run lint` clean

**Client (Drift, `apps/plot/lib/store`):**
- Add `TextColumn get dismissedFocusSuggestions =>
  text().nullable().map(const StringListConverter())()` to `UserSettings`.
- Add a `StringListConverter` (JSON array of strings ⇄ `List<String>`) following
  the existing `*ListConverter` pattern in the store, if no string-list converter
  already exists.
- Bump `Store.schemaVersion` and add an `addColumn` migration step in
  `Store.migration.onUpgrade`.
- `flutter pub run build_runner build` to regenerate `store.g.dart`.

`UserSettingsEntity.push()/pull()` already serialize every column generically, so
no sync wiring changes are needed beyond the new column round-tripping correctly
(verify the local JSON-string ⇄ server jsonb-array round-trip during
implementation, matching how `thread.contacts` round-trips).

## Data flow

1. User triggers "Add a focus" → `AddFocus.run` loads dismissed set.
2. If suggestions remain → picker modal; else → `NewFocus()` directly.
3. User picks "Create a custom focus" → `NewFocus()`; or a suggestion →
   `NewFocus(prefill: suggestion)` (fields, incl. description, prefilled).
4. User completes the two-step form and creates the focus → `save()` succeeds.
5. If the focus came from a suggestion (`suggestionKey != null`),
   `DismissedFocusSuggestions.add(key)` writes the updated array to
   `user_settings`, which syncs to the server and out to the user's other
   devices.
6. On any device, the picker filters `kFocusSuggestions` by the synced dismissed
   set, so that suggestion no longer appears.

## Edge cases

- **No `user_settings` row yet** (fresh user): dismissed set is empty → all
  suggestions shown. First `add()` creates the row via `UserSettingsEntity.save`.
- **Concurrent edits on two devices**: last-write-wins on the whole array (the
  existing `seq`/`updated_at` sync semantics). Acceptable — at worst a suggestion
  briefly reappears until the next sync; `add()` dedups.
- **Form cancelled / matching fetch fails then user backs out**: no `save()`, so
  no dismissal. Correct.
- **Unknown keys in the stored array** (e.g. a suggestion later removed from
  `kFocusSuggestions`): harmless — filtering ignores keys with no matching
  suggestion.

## Testing

- Unit: `DismissedFocusSuggestions.get/add` (empty → add → dedup → persisted).
- Unit: `AddFocus` shortcut — all dismissed → runs `NewFocus()` directly; some
  remaining → builds picker with the right rows.
- Unit: suggestion-key threading — `_CreateFocusWithThreads` / `AddPriority`
  carry the key from a prefilled form to the dismissal write.
- `flutter analyze` clean.
- DB: `pnpm diff-schema-migrations` and `db:lint` clean after migration.

## Files touched

- `apps/plot/lib/command/focus_suggestions.dart` — **new**: `kFocusSuggestions`
  list (the 11 entries with stable keys).
- `apps/plot/lib/command/priority.dart` — `FocusPrefill.suggestionKey`,
  `AddFocus` + `_CreateCustomFocus` + `_CreateSuggestedFocus`, key threading into
  `AddPriority` / `_CreateFocusWithThreads`, `DismissedFocusSuggestions` helper
  (or its own file).
- `apps/plot/lib/widget/priorities_list.dart` — sidebar button → `AddFocus()`.
- `apps/plot/lib/command/global.dart` — palette → `AddFocus()`.
- `apps/plot/lib/widget/onboarding/onboarding_roles.dart` — **deleted**.
- `apps/plot/lib/widget/onboarding/onboarding_steps.dart` — remove dead import.
- `apps/plot/lib/store/user_settings.dart` + store converter + `store.dart`
  migration/`schemaVersion` — new column.
- `libs/db/schema/50-tables/99-user-settings.sql` + generated migration +
  `libs/db/src/types.ts`.
```

# Pin to Thread — restore the top-of-thread display

**Date:** 2026-06-24
**Status:** Approved design, ready for implementation plan
**Area:** Flutter app (`apps/plot/`)

## Problem

The "Pin to thread" action still exists in the `…` menu of a note-attached link
(`apps/plot/lib/widget/note_action.dart:664`, handler `_pinLink()` at `:696`).
It writes a canonical `LinkRow` (`threadId` set, `noteScoped: false`) that syncs
correctly. But the widget that rendered canonical links as rows above the notes
list was deliberately deleted in commit `e896b5a96` (2026-06-08,
"feat(thread): replace per-link rows with header status icon + join-meeting
button"), which removed `_ThreadLinkRow` and friends (−541 lines from
`thread.dart`) and replaced them with the slim `PrimaryLinkHeaderActions`
(join-meeting button + status icon for the **primary** link only).

Consequence: pinning a plain bookmark URL now produces **no visible link** in the
thread. A pinned bookmark has no type config and no actions, so
`PrimaryLinkHeaderActions` renders nothing for it (confirmed: `StatusIconButton`
returns `SizedBox.shrink()` when `getTypeConfig() == null` —
`status_icon_button.dart:50-58`). There is also no longer any unpin affordance,
so a pinned link is stranded. Two store methods that backed the old row's menu
are now dead code with zero callers: `Link.updateTitleAndUrl` (`link.dart:659`)
and `Link.unpinFromThread` (`link.dart:680`).

## Goal

Make user-pinned bookmark links visible again as rows at the top of the thread,
with the ability to open, edit, and unpin them — **without** resurrecting the
rich connector-link row UI (status/assignee/conferencing badges) that the
2026-06-08 redesign intentionally moved into the header.

## Scope decisions (resolved during brainstorming)

1. **Which links render as rows:** only **user-pinned bookmarks** — canonical
   links with no connector type config. Connector-managed canonical links
   (calendar events, Linear issues, etc.) keep today's header treatment
   (`PrimaryLinkHeaderActions`). The discriminator is the same "user-editable"
   test the old code used: `link.getTypeConfig() == null && link.sourceUrl != null`.
2. **Row affordances:** tapping the row opens the URL externally; a `…` menu
   offers **Edit link** and **Unpin from thread** (full restore of the old
   bookmark menu). Both back onto the existing dead store methods.

## Non-goals (YAGNI)

- No status / assignee / conferencing badges in the rows.
- No change to `PrimaryLinkHeaderActions` (the header surface for connector
  links). Bookmarks produce nothing there, so there is no duplication.
- No shared-tile refactor unifying these rows with note-attached link rows.
- No "Connect your account" sub-label (that was connector-only; bookmarks have
  `createdBy == null` so they are always "connected").
- No database schema, sync, API, or migration changes.
- No change to the pin action itself (`_pinLink()` already writes the row
  correctly, including its "Link already pinned" dedupe toast).

## Architecture

### New widget: `apps/plot/lib/widget/pinned_link_row.dart`

`PinnedLinkRow extends StatelessWidget` — renders one bookmark `Link`:

- **Input:** `final Link link;` (a canonical, type-config-less bookmark).
- **Visual** (mirrors the old `_ThreadLinkRow` so placement is pixel-identical):
  - Wrapped in `FTheme(data: darkenTheme(context, context.theme, context.colour, steps: 2))`.
  - `DecoratedBox` with `background` fill and a `Border(bottom: 0.5px, border colour)`.
  - Padding: `horizontal: context.isMultiPanel ? 20.0 : context.contentPaddingH`, `vertical: 6`.
  - `Row`: logo (`link.logoForBrightness(brightness)` via `LogoImage`, fallback
    `Icon(PlotIcon.link, size: 14)`) + 8px gap + `Expanded` title
    (`link.title ?? ''`, `sm` typography, `ellipsis`, `maxLines: 1`,
    foreground darkens on hover) + the trailing `…` menu.
- **Tap (open):** `GestureDetector` over the row; `Uri.tryParse(link.sourceUrl)`,
  bail if null, else `launchUrl(uri, mode: LaunchMode.externalApplication)`.
  `MouseRegion(cursor: SystemMouseCursors.click)` — this is a true external link,
  which the project's pointer-cursor rule permits (reserve pointer for real
  URL navigation). Local hover state may be a small `StatefulWidget` or a
  `HookWidget` for the title colour shift; keep it self-contained.

### Trailing menu: `_PinnedLinkMenu` (private, in the same file)

Stateful `OverlayPortal`-based `…` button (`Icon(PlotIcon.more, size: 14)`,
`SystemMouseCursors.basic`), styled with `context.theme.popoverMenuStyle`,
mirroring the structure of the existing `_NoteLinkMenu` in `note_action.dart`.
Two items:

- **Edit link** → open `EditLinkModal(initialTitle: link.title, initialUrl:
  link.sourceUrl).run(context)`; if a result returns and differs, call
  `Link.updateTitleAndUrl(link, title: result.title, url: result.url)`.
- **Unpin from thread** → `Link.unpinFromThread(link)`.

Both `Link.updateTitleAndUrl` and `Link.unpinFromThread` already exist and
require no changes.

### Wiring in `apps/plot/lib/page/thread.dart`

In `_ThreadPageContent`'s build, at the slot where the old rows lived (currently
between `_ThreadFilterBar` (`:751`) and the notes `Flexible` (`:755`)), insert:

```dart
...state.links
    .where((l) => l.getTypeConfig() == null && l.sourceUrl != null)
    .map((link) => PinnedLinkRow(link: link)),
```

`ThreadState.links` is fed by `Link.watchForThread` (`thread.dart:493`), which
returns only canonical (non-note-scoped) links, primary-first. So unpinning (or
a connector dropping a link) updates the rows reactively with no extra plumbing.
Filtering happens in the page, not the widget, per the project's page/widget
separation.

## Data flow

1. User pins a note link → `_pinLink()` writes a canonical `LinkRow`
   (`threadId` set, `noteScoped: false`, `getTypeConfig() == null`).
2. `Link.watchForThread(threadId)` emits the updated canonical list →
   `ThreadBloc` emits `state.copyWith(links: …)`.
3. The page filters to bookmarks and renders one `PinnedLinkRow` each above the
   notes list.
4. Edit/Unpin write via the existing store methods; unpin nulls `threadId`, the
   stream drops the link, the row disappears.

## In-scope side effect

The bookmark predicate also surfaces canonical bookmark links created by "new
thread with a link" (`AddThreadWithLink`), which are equally type-config-less
and equally invisible today. Rendering them as a top row is the same fix and is
consistent behaviour.

## Error handling

- `launchUrl` failure / unparseable URL is an expected, user-facing case —
  guard with `Uri.tryParse` and return; no `captureException` (matches the old
  code and the project rule to capture only *unexpected* errors).
- Store writes go through Drift `.save()`, which propagates errors normally.
- No new catch-blocks for unexpected errors are introduced.

## Testing (TDD)

`PinnedLinkRow` widget tests:
- Renders the title; falls back to `PlotIcon.link` when no logo.
- Tapping the row opens `sourceUrl` externally (mock `url_launcher`).
- `…` menu exposes "Edit link" and "Unpin from thread".
- Selecting "Unpin from thread" calls `Link.unpinFromThread(link)`.
- Selecting "Edit link" with a changed result calls `Link.updateTitleAndUrl`.

Page-level (`thread.dart`) test:
- A thread whose canonical links include one bookmark (no type config) renders
  exactly one `PinnedLinkRow` above the notes.
- A thread whose canonical link has a type config (connector-managed) renders
  **zero** `PinnedLinkRow`s (it stays a header-only concern).

## Files touched

| File | Change |
|------|--------|
| `apps/plot/lib/widget/pinned_link_row.dart` | **New** — `PinnedLinkRow` + private `_PinnedLinkMenu`. |
| `apps/plot/lib/page/thread.dart` | Insert the filtered `PinnedLinkRow` list at the old row slot; import the new widget. |
| `apps/plot/lib/store/link.dart` | None expected — `updateTitleAndUrl` / `unpinFromThread` reused as-is (they stop being dead code). |
| `apps/plot/test/...` | New widget + page tests. |

## Finalization notes

- Run `flutter analyze` (lint) before completing.
- Add a short user-facing bullet to `docs/updates.md` under `## Next release`
  (e.g. a `### Threads`/links section): pinned links appear at the top of a
  thread again, and can be opened, edited, or unpinned.
- No `public/` submodule changes; no changeset.

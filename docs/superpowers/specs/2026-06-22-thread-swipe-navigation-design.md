# Swipe Between Threads — Gmail-style Carousel

**Date:** 2026-06-22
**Status:** Approved design, ready for implementation plan
**Scope:** Flutter app (`apps/plot/`), iOS + Android native only

## Summary

When viewing a single thread on a touch device, the user can drag horizontally to
move to the next / previous thread in the same feed — the way Gmail lets you swipe
between emails. The incoming thread follows the finger as a true carousel.

This is a touch-input affordance layered on top of navigation logic that already
exists: keyboard `OpenNextThread` / `OpenPreviousThread` (up/down arrows) already
walk the ordered feed via `PriorityBloc.getActivityFeedItem(offset)`. The new work
is the finger-following gesture surface and the recentering carousel, not the
"find the neighbor" logic.

## Decisions (locked)

1. **Feel:** true finger-following carousel — the adjacent thread tracks the finger
   and slides in as you drag.
2. **iOS back gesture:** a thin (~20pt) left-edge strip is reserved for the system
   edge-swipe-back-to-list. Drags starting elsewhere drive the carousel.
3. **Platform scope:** iOS + Android native only. Desktop/web keep keyboard arrows
   and clicks, unchanged.
4. **Neighbor rendering:** off-center threads render as a **lightweight read-only
   preview** (no `ThreadBloc`, no editor, no DB subscriptions, never marked read).
   On settle, the landed neighbor is **promoted** to the full live thread.

## Direction mapping

- **Swipe left** (content drags leftward) → **next** thread (`offset +1`, further
  down the feed).
- **Swipe right** (content drags rightward) → **previous** thread (`offset -1`).

Gmail-standard. Matches the existing keyboard down=next / up=previous semantics.

## Architecture

### Hosting

A new `ThreadCarousel` widget wraps the thread view **inside the existing
`ThreadRoute`** (`apps/plot/lib/page/thread.dart`). Swiping does **not** push a new
route, so:

- The back stack never grows as the user swipes through many threads.
- Back (iOS chevron / iOS edge strip / Android back) always returns to the **list**,
  not to the previously-swiped thread.

On platforms outside the iOS+Android gate, `ThreadPage` renders the plain single
`_ThreadPageContent` exactly as it does today — the carousel wrapper is not built.
The platform check is `!kIsWeb && (Platform.isIOS || Platform.isAndroid)` so
`dart:io` `Platform` is never reached on web.

### The 3-page recentering carousel

A `PageView` with three slots, controller resting at index 1:

| Index | Content |
|-------|---------|
| 0 — previous | read-only preview of `getActivityFeedItem(-1)` |
| 1 — center | the **live** `_ThreadPageContent` (today's thread view, unchanged) |
| 2 — next | read-only preview of `getActivityFeedItem(+1)` |

When a swipe settles on index 0 or 2:

1. That neighbor's thread becomes the new center.
2. `PriorityBloc.state.thread` is updated (carrying the same `ThreadListSource`).
3. The route's thread param is kept in sync without a transition (see "Route/URL
   sync").
4. Neighbors are recomputed from the feed.
5. The controller snaps back to index 1 with **no animation**.

This is the standard infinite-carousel recentering pattern; the user never reaches a
visible edge of the `PageView` except at the true ends of the feed.

### Neighbor previews

A new lightweight read-only widget renders a neighbor using the `AgendaThreadItem`
the feed **already holds** (thread + representative note). It creates:

- **no** `ThreadBloc` / `ThreadBlocProvider`
- **no** Drift stream subscriptions
- **no** `NoteEditor`
- **no** mark-as-read timer

So neighbors cannot be marked read, cannot steal keyboard focus, and add negligible
cost. The preview shows the thread title/header and the representative note(s) from
the feed item — believable incoming content during a drag. Full note history loads
only after promotion, when the live `_ThreadPageContent` mounts.

### Neighbor lookup & ordering

Reuses `PriorityBloc.getActivityFeedItem(offset)` (`apps/plot/lib/state/priority.dart`)
against the same feed (`ThreadListSource`) the thread was opened from. No new ordering
logic is introduced. The carousel listens to `PriorityBloc` so neighbors stay correct
if the feed reorders while the thread is open.

### Boundaries & fallback

- **First thread:** `getActivityFeedItem(-1)` yields no thread → no previous page →
  the carousel rubber-bands on a right-swipe.
- **Last loaded thread:** `getActivityFeedItem(+1)` yields no thread → no next page →
  rubber-bands on a left-swipe. **v1 does not auto-paginate** the feed at the end
  (noted as a future enhancement).
- **No list context** — deep-linked `/t/…` thread, or a thread filtered out of the
  feed by an active search: `getActivityFeedItem` returns null both directions →
  the carousel is **inert** and renders exactly today's single static thread. Safe,
  no behavior change in that case.

### iOS left-edge back zone

The `PageView` ignores horizontal drags that **start within ~20pt of the left edge**,
letting Cupertino's `_CupertinoBackGestureDetector` win the gesture arena there and
preserve edge-swipe-back-to-list. Drags starting elsewhere drive the carousel.
Android's back is a navigator-level button/gesture, so no edge zone is needed on
Android.

### Route / URL sync

On promotion, `PriorityBloc.state.thread` is updated and the route's thread param is
kept in sync **without a transition**. Because this is mobile-only, the URL is not
user-visible; the invariants that matter are:

- **Back returns to the list** (single route — guaranteed by not pushing per swipe).
- **`state.thread` reflects the centered thread** (so share, actions, and re-open
  target the right thread).

The exact mechanism (auto_route replace-without-animation vs. updating the param in
place) is an implementation detail resolved in the plan; it does not change UX.

## Side-effect gating (why this is safe)

The investigation found three render-time side effects in `_ThreadPageContent` that
would misfire if neighbors were fully live:

1. **Mark-as-read** fires from `didChangeDependencies` →
   `_scheduleMarkAsRead` (`thread.dart:139,215`). Because neighbors are previews with
   no `ThreadBloc`, this never runs for them — only the promoted center marks read.
2. **`ThreadBloc` subscriptions** (4–5 Drift streams per thread, started in the
   constructor, `state/thread.dart:33`) — only one is ever alive (the center).
3. **`NoteEditor` autofocus** (`note_editor.dart:211`, true when a physical keyboard
   is present) — previews have no editor, so no focus thrashing.

## Components

- `ThreadCarousel` — new stateful widget; owns the `PageController`, the center
  thread, the prev/next `AgendaItem`s, and the recentering logic. Listens to
  `PriorityBloc` for neighbor recomputation. Applies the platform gate and the
  left-edge zone.
- `ThreadPreview` (name TBD) — new lightweight read-only widget rendering a neighbor
  from an `AgendaThreadItem`. No bloc, no editor, no subscriptions.
- `ThreadPage` / `_ThreadPageContent` (`apps/plot/lib/page/thread.dart`) — wrapped by
  `ThreadCarousel` on iOS/Android; otherwise rendered directly as today. The live
  center is an unchanged `_ThreadPageContent`.
- `PriorityBloc.getActivityFeedItem(offset)` — reused unchanged for neighbor lookup.
- `PriorityBloc.setThread` — reused to update the centered thread on promotion.

## Testing

Widget tests (iOS/Android gate forced on):

- Swipe-left promotes the next feed thread; `state.thread` updates to it.
- Swipe-right promotes the previous feed thread.
- At the first thread, right-swipe rubber-bands (no previous page); at the last
  loaded thread, left-swipe rubber-bands (no next page).
- Deep-link / search-filtered thread (not in feed) → carousel inert, single thread
  renders, no preview pages.
- **Only the centered thread is marked read** — promoting a neighbor marks the new
  center read; a thread that was only ever a preview is never marked read.
- Swiping repeatedly does **not** grow the navigator back stack; Back returns to the
  list.
- A drag starting in the left-edge zone on iOS does not move the carousel.
- Platform gate: on desktop/web the carousel widget is absent and the plain
  `_ThreadPageContent` renders.

## Out of scope (v1)

- Auto-paginating the feed when swiping past the last loaded thread.
- Carousel on web / touchscreen desktop.
- Changing keyboard navigation behavior.
- Full note history in the preview (previews intentionally show only the feed's
  representative note until promotion).

## Docs to update on completion

- `docs/updates.md` — `## Next release` → `### Fixes` or a `### Threads`-style section:
  plain-language "swipe between threads on mobile."
- `docs/features.md` if it enumerates mobile gestures.

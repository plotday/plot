# Swipe Between Threads (Gmail-style Carousel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On iOS and Android, let the user drag horizontally while viewing a thread to move to the next / previous thread in the same feed, the way Gmail swipes between emails.

**Architecture:** A new `ThreadCarousel` widget hosts a horizontal `PageView` with the live thread at the center and lightweight read-only previews of the neighbor threads on either side. Swiping settles on a neighbor, which "promotes" it to the live thread via `PriorityBloc.setThread`. The carousel is wired in only on iOS/Android inside the existing `ThreadRoute` — no new routes are pushed, so the back stack never grows and Back always returns to the list. Neighbors are resolved with the existing `PriorityBloc.getActivityFeedItem(offset)`.

**Tech Stack:** Flutter, flutter_bloc (Cubit), forui, auto_route, Drift store models. Tests use `flutter_test` widget tests with stub builders and spy callbacks.

## Global Constraints

- **Platform gate:** carousel only on `!kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android)`. Never touch `dart:io` `Platform` (use `defaultTargetPlatform` from `package:flutter/foundation.dart`, which is safe on web).
- **Direction:** swipe left → next thread (`getActivityFeedItem(1)`); swipe right → previous thread (`getActivityFeedItem(-1)`).
- **Imports:** only `package:flutter/widgets.dart`, `package:flutter/foundation.dart`, `package:flutter/rendering.dart`, and `package:forui/forui.dart` for UI — never `package:flutter/material.dart`. Group imports dart → flutter → third-party → local.
- **Blocs only in pages/commands, never in widgets.** `ThreadCarousel` and `ThreadPreview` take plain data + callbacks; all `PriorityBloc`/`ThreadBloc` access stays in `page/thread.dart`.
- **UI text:** sentence case.
- **No new mark-as-read code.** Only the live center mounts `_ThreadPageContent`; previews never do, so mark-as-read is gated by construction. Do not add gating logic to `thread.dart`'s `_scheduleMarkAsRead`.
- **No route pushing on swipe.** A swipe calls `PriorityBloc.setThread(thread)` only. Back keeps popping the single `ThreadRoute` to the list.
- **Lint:** `cd apps/plot && flutter analyze` must be clean before each commit.
- **No schema changes.** This is UI-only.

---

## File Structure

- **Create** `apps/plot/lib/util/thread_carousel_nav.dart` — two pure helpers: `shouldUseThreadCarousel(...)` (platform gate) and `threadFromAgendaItem(...)` (extract a `Thread?` from an `AgendaItem?`).
- **Create** `apps/plot/lib/widget/thread_preview.dart` — `ThreadPreview`, a lightweight read-only render of a `Thread` (title + preview snippet). No bloc, no editor, no subscriptions.
- **Create** `apps/plot/lib/widget/thread_carousel.dart` — `ThreadCarousel`, the `PageView` carousel with center + neighbor previews, swipe-to-promote, recentering, and the iOS left-edge back zone.
- **Modify** `apps/plot/lib/page/thread.dart` — extract `_buildLiveThread(ThreadId)`; in `ThreadPage.wrappedRoute`, branch to the carousel on iOS/Android, otherwise return today's single live thread unchanged.
- **Create** tests:
  - `apps/plot/test/util/thread_carousel_nav_test.dart`
  - `apps/plot/test/widget/thread_preview_test.dart`
  - `apps/plot/test/widget/thread_carousel_test.dart`
- **Modify** `apps/plot/docs/updates.md` — user-facing bullet.

---

## Task 1: Pure navigation helpers

**Files:**
- Create: `apps/plot/lib/util/thread_carousel_nav.dart`
- Test: `apps/plot/test/util/thread_carousel_nav_test.dart`

**Interfaces:**
- Produces:
  - `bool shouldUseThreadCarousel({required bool isWeb, required TargetPlatform platform})`
  - `Thread? threadFromAgendaItem(AgendaItem? item)`

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/util/thread_carousel_nav_test.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/thread_carousel_nav.dart';

Priority _testPriority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path('test'),
    order: Order(0),
    unread: false,
    role: 'member',
    isInbox: false,
    isFyi: false,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  group('shouldUseThreadCarousel', () {
    test('enabled on native iOS and Android', () {
      expect(
        shouldUseThreadCarousel(isWeb: false, platform: TargetPlatform.iOS),
        isTrue,
      );
      expect(
        shouldUseThreadCarousel(isWeb: false, platform: TargetPlatform.android),
        isTrue,
      );
    });

    test('disabled on web even for a mobile platform', () {
      expect(
        shouldUseThreadCarousel(isWeb: true, platform: TargetPlatform.iOS),
        isFalse,
      );
    });

    test('disabled on desktop platforms', () {
      for (final p in [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(shouldUseThreadCarousel(isWeb: false, platform: p), isFalse);
      }
    });
  });

  group('threadFromAgendaItem', () {
    final priority = _testPriority();

    test('returns the thread for a thread item', () {
      final thread = Thread(priority: priority, title: 'hi');
      expect(threadFromAgendaItem(AgendaThreadItem(thread))?.id, thread.id);
    });

    test('returns null for a header item and for null', () {
      expect(threadFromAgendaItem(null), isNull);
      expect(
        threadFromAgendaItem(const AgendaHeaderItem(date: null)),
        isNull,
      );
    });
  });
}
```

Note: confirm the `AgendaHeaderItem` constructor signature in `lib/state/agenda_model.dart:406`; if it differs, build the simplest valid header item for the null case (the assertion only needs *a* header item).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/util/thread_carousel_nav_test.dart`
Expected: FAIL — `thread_carousel_nav.dart` does not exist / functions undefined.

- [ ] **Step 3: Write minimal implementation**

Create `apps/plot/lib/util/thread_carousel_nav.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

/// Whether the swipe-between-threads carousel should be used.
///
/// Touch-only: native iOS and Android. Web (even on a mobile device) and
/// desktop keep keyboard arrows / clicks and render the single thread view.
bool shouldUseThreadCarousel({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  if (isWeb) return false;
  return platform == TargetPlatform.iOS ||
      platform == TargetPlatform.android;
}

/// Extracts the [Thread] from an [AgendaItem], or null for headers / null.
Thread? threadFromAgendaItem(AgendaItem? item) {
  if (item == null) return null;
  return item.when<Thread?>(
    header: (_) => null,
    activity: (a) => a.thread,
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/util/thread_carousel_nav_test.dart`
Expected: PASS (all cases).

- [ ] **Step 5: Analyze and commit**

```bash
cd apps/plot && flutter analyze lib/util/thread_carousel_nav.dart test/util/thread_carousel_nav_test.dart
git add apps/plot/lib/util/thread_carousel_nav.dart apps/plot/test/util/thread_carousel_nav_test.dart
git commit -m "feat(app): pure helpers for thread swipe carousel (platform gate + neighbor extract)"
```

---

## Task 2: `ThreadPreview` widget

A read-only, non-interactive render of a neighbor thread, built only from the
`Thread` object already in memory (no `ThreadBloc`, no `NoteEditor`, no DB
subscriptions). Shows the thread title and the preview snippet.

**Files:**
- Create: `apps/plot/lib/widget/thread_preview.dart`
- Test: `apps/plot/test/widget/thread_preview_test.dart`

**Interfaces:**
- Produces: `class ThreadPreview extends StatelessWidget` with `const ThreadPreview({required Thread thread, Key? key})`.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/widget/thread_preview_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/note_editor.dart';
import 'package:plot/widget/thread_preview.dart';

Priority _testPriority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path('test'),
    order: Order(0),
    unread: false,
    role: 'member',
    isInbox: false,
    isFyi: false,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

Widget _host(Widget child) => FTheme(
      data: FThemes.zinc.light,
      child: Directionality(textDirection: TextDirection.ltr, child: child),
    );

void main() {
  final priority = _testPriority();

  testWidgets('renders the thread title', (tester) async {
    final thread = Thread(priority: priority, title: 'Weekly sync');
    await tester.pumpWidget(_host(ThreadPreview(thread: thread)));
    expect(find.text('Weekly sync'), findsOneWidget);
  });

  testWidgets('never mounts a NoteEditor', (tester) async {
    final thread = Thread(priority: priority, title: 'No editor here');
    await tester.pumpWidget(_host(ThreadPreview(thread: thread)));
    expect(find.byType(NoteEditor), findsNothing);
  });

  testWidgets('is non-interactive (wrapped in IgnorePointer)', (tester) async {
    final thread = Thread(priority: priority, title: 'Read only');
    await tester.pumpWidget(_host(ThreadPreview(thread: thread)));
    expect(find.byType(IgnorePointer), findsWidgets);
  });
}
```

Note: if `FTheme`/`FThemes.zinc` is not the project's standard test host, copy the host wrapper from an existing widget test in `test/widget/` that renders forui widgets. The assertions are what matter.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/thread_preview_test.dart`
Expected: FAIL — `thread_preview.dart` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `apps/plot/lib/widget/thread_preview.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';

/// A lightweight, read-only render of a neighbor thread for the swipe
/// carousel. Built entirely from the in-memory [Thread] (title + preview
/// snippet) — it creates no [ThreadBloc], no note subscriptions, and no
/// editor, so it never marks the thread read or claims keyboard focus. The
/// full thread view mounts only when the swipe settles and the thread is
/// promoted to the carousel center.
class ThreadPreview extends StatelessWidget {
  const ThreadPreview({required this.thread, super.key});

  final Thread thread;

  @override
  Widget build(BuildContext context) {
    final theme = FTheme.of(context);
    final title = thread.title?.trim();
    final preview = thread.displayPreview?.trim();

    return IgnorePointer(
      child: Container(
        color: theme.colors.background,
        padding: EdgeInsets.all(Spacing.lg),
        alignment: Alignment.topLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null && title.isNotEmpty)
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.lg,
              ),
            if (preview != null && preview.isNotEmpty) ...[
              SizedBox(height: Spacing.sm),
              Text(
                preview,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.sm
                    .copyWith(color: theme.colors.mutedForeground),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
```

Note: verify the forui theme accessors (`FTheme.of(context)`, `theme.colors.background`, `theme.typography.lg`, `theme.colors.mutedForeground`) against a current widget in `lib/widget/`. If the project exposes a thread-style header/snippet widget that is genuinely subscription-free, reuse it instead of hand-rolling — but do **not** reuse `ThreadWidget` (it is the list row, not a thread-page render) or anything that takes a `ThreadBloc`. Verify `Spacing.lg/sm` constants exist in `lib/style/spacing.dart`; adjust names to match.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/thread_preview_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze and commit**

```bash
cd apps/plot && flutter analyze lib/widget/thread_preview.dart test/widget/thread_preview_test.dart
git add apps/plot/lib/widget/thread_preview.dart apps/plot/test/widget/thread_preview_test.dart
git commit -m "feat(app): ThreadPreview read-only neighbor render for swipe carousel"
```

---

## Task 3: `ThreadCarousel` widget — structure, swipe-to-promote, recentering

The carousel renders a horizontal `PageView`: `[previousPreview?, liveCenter, nextPreview?]`. The live center is built via an injected `centerBuilder(ThreadId)` wrapped in a `KeyedSubtree(key: ValueKey(centerThreadId))` so it is preserved across unrelated rebuilds (and only one live thread is ever mounted). Settling on a neighbor calls `onOpenNeighbor(thread)`. When the center thread id changes (promotion) or a neighbor appears/disappears, the controller re-centers on the live page. With no neighbors the carousel is inert (single page, nothing to swipe to).

**Files:**
- Create: `apps/plot/lib/widget/thread_carousel.dart`
- Test: `apps/plot/test/widget/thread_carousel_test.dart`

**Interfaces:**
- Consumes: `Thread`, `ThreadId` from `plot/store/store.dart`.
- Produces:
  ```dart
  typedef ThreadCenterBuilder = Widget Function(ThreadId threadId);
  typedef ThreadPreviewBuilder = Widget Function(Thread thread);

  class ThreadCarousel extends StatefulWidget {
    const ThreadCarousel({
      required ThreadId centerThreadId,
      required Thread? previous,
      required Thread? next,
      required ThreadCenterBuilder centerBuilder,
      required ThreadPreviewBuilder previewBuilder,
      required void Function(Thread thread) onOpenNeighbor,
      bool reserveLeftEdgeBackZone = false,
      double edgeZoneWidth = 20,
      Key? key,
    });
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `apps/plot/test/widget/thread_carousel_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/thread_carousel.dart';

Priority _testPriority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path('test'),
    order: Order(0),
    unread: false,
    role: 'member',
    isInbox: false,
    isFyi: false,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  final priority = _testPriority();
  Thread mk(String title) => Thread(priority: priority, title: title);

  // Build a carousel whose center/preview are cheap stubs, recording opens.
  Widget host({
    required Thread center,
    Thread? previous,
    Thread? next,
    required List<Thread> opened,
    bool reserveLeftEdgeBackZone = false,
  }) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 400,
        height: 800,
        child: ThreadCarousel(
          centerThreadId: center.id,
          previous: previous,
          next: next,
          centerBuilder: (id) => Center(child: Text('center:$id')),
          previewBuilder: (t) => Center(child: Text('preview:${t.id}')),
          onOpenNeighbor: opened.add,
          reserveLeftEdgeBackZone: reserveLeftEdgeBackZone,
        ),
      ),
    );
  }

  testWidgets('renders the live center', (tester) async {
    final c = mk('center');
    await tester.pumpWidget(host(center: c, opened: []));
    expect(find.text('center:${c.id}'), findsOneWidget);
  });

  testWidgets('inert with no neighbors: swipe does not open anything',
      (tester) async {
    final c = mk('only');
    final opened = <Thread>[];
    await tester.pumpWidget(host(center: c, opened: opened));
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });

  testWidgets('swipe left opens the next thread', (tester) async {
    final c = mk('center');
    final n = mk('next');
    final opened = <Thread>[];
    await tester.pumpWidget(host(center: c, next: n, opened: opened));
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(opened.map((t) => t.id), [n.id]);
  });

  testWidgets('swipe right opens the previous thread', (tester) async {
    final c = mk('center');
    final p = mk('prev');
    final opened = <Thread>[];
    await tester.pumpWidget(host(center: c, previous: p, opened: opened));
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(opened.map((t) => t.id), [p.id]);
  });

  testWidgets('at first thread (no previous), swipe right rubber-bands',
      (tester) async {
    final c = mk('first');
    final n = mk('next');
    final opened = <Thread>[];
    await tester.pumpWidget(host(center: c, next: n, opened: opened));
    // Drag right — there is no previous page, so nothing should open.
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/plot && flutter test test/widget/thread_carousel_test.dart`
Expected: FAIL — `thread_carousel.dart` does not exist.

- [ ] **Step 3: Write the implementation**

Create `apps/plot/lib/widget/thread_carousel.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:plot/store/store.dart';

typedef ThreadCenterBuilder = Widget Function(ThreadId threadId);
typedef ThreadPreviewBuilder = Widget Function(Thread thread);

/// A Gmail-style horizontal carousel for navigating between threads by swipe.
///
/// Renders `[previousPreview?, liveCenter, nextPreview?]` in a [PageView].
/// The live center is the real thread view (built by [centerBuilder]); the
/// neighbors are cheap read-only previews ([previewBuilder]). Settling on a
/// neighbor calls [onOpenNeighbor], which the host wires to
/// `PriorityBloc.setThread` — promoting that thread to the center. Only one
/// live thread is ever mounted (the center), so neighbors never mark read or
/// claim focus.
///
/// No routes are pushed: the host stays on a single `ThreadRoute`, so Back
/// always returns to the list and the back stack never grows.
class ThreadCarousel extends StatefulWidget {
  const ThreadCarousel({
    required this.centerThreadId,
    required this.previous,
    required this.next,
    required this.centerBuilder,
    required this.previewBuilder,
    required this.onOpenNeighbor,
    this.reserveLeftEdgeBackZone = false,
    this.edgeZoneWidth = 20,
    super.key,
  });

  /// The id of the thread currently centered/live.
  final ThreadId centerThreadId;

  /// The neighbor threads, or null at a feed boundary / when there is no list
  /// context (deep link, search-filtered). A null side cannot be swiped to.
  final Thread? previous;
  final Thread? next;

  final ThreadCenterBuilder centerBuilder;
  final ThreadPreviewBuilder previewBuilder;

  /// Called when a swipe settles on a neighbor. The host promotes [thread] to
  /// the center (e.g. `PriorityBloc.setThread(thread)`).
  final void Function(Thread thread) onOpenNeighbor;

  /// On iOS, reserve a strip at the very left edge for the system
  /// edge-swipe-back gesture instead of the carousel.
  final bool reserveLeftEdgeBackZone;
  final double edgeZoneWidth;

  @override
  State<ThreadCarousel> createState() => _ThreadCarouselState();
}

class _ThreadCarouselState extends State<ThreadCarousel> {
  late PageController _controller;

  /// True while the active pointer started inside the reserved left-edge
  /// zone; the PageView is frozen so the route's back gesture can win.
  bool _edgeBlocked = false;

  int get _centerIndex => widget.previous != null ? 1 : 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: _centerIndex);
  }

  @override
  void didUpdateWidget(ThreadCarousel old) {
    super.didUpdateWidget(old);
    final oldCenterIndex = old.previous != null ? 1 : 0;
    final centerChanged = old.centerThreadId != widget.centerThreadId;
    final indexChanged = oldCenterIndex != _centerIndex;
    if (centerChanged || indexChanged) {
      // A neighbor was promoted, or a neighbor appeared/disappeared while the
      // same thread stayed centered. Re-center the controller on the live page
      // after the new children lay out.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.hasClients) {
          _controller.jumpToPage(_centerIndex);
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    if (index == _centerIndex) return;
    final thread = index < _centerIndex ? widget.previous : widget.next;
    if (thread != null) widget.onOpenNeighbor(thread);
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      if (widget.previous != null) widget.previewBuilder(widget.previous!),
      KeyedSubtree(
        key: ValueKey(widget.centerThreadId),
        child: widget.centerBuilder(widget.centerThreadId),
      ),
      if (widget.next != null) widget.previewBuilder(widget.next!),
    ];

    final pageView = PageView(
      controller: _controller,
      physics: _edgeBlocked
          ? const NeverScrollableScrollPhysics()
          : null, // default PageScrollPhysics (platform-appropriate)
      onPageChanged: _onPageChanged,
      children: pages,
    );

    if (!widget.reserveLeftEdgeBackZone) return pageView;

    // Freeze the PageView for any gesture that begins in the left-edge strip
    // so the route's edge-swipe-back recognizer wins the arena there.
    return Listener(
      onPointerDown: (event) {
        final blocked = event.localPosition.dx <= widget.edgeZoneWidth;
        if (blocked != _edgeBlocked) setState(() => _edgeBlocked = blocked);
      },
      onPointerUp: (_) {
        if (_edgeBlocked) setState(() => _edgeBlocked = false);
      },
      onPointerCancel: (_) {
        if (_edgeBlocked) setState(() => _edgeBlocked = false);
      },
      child: pageView,
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/plot && flutter test test/widget/thread_carousel_test.dart`
Expected: PASS (5 tests: renders center, inert, swipe-left→next, swipe-right→prev, first-thread rubber-band).

If `fling` does not reliably cross the page-settle threshold in the test environment, replace it with an explicit drag of slightly more than half the carousel width, e.g. `await tester.drag(find.byType(PageView), const Offset(-250, 0)); await tester.pumpAndSettle();` (carousel width is 400 in the host).

- [ ] **Step 5: Analyze and commit**

```bash
cd apps/plot && flutter analyze lib/widget/thread_carousel.dart test/widget/thread_carousel_test.dart
git add apps/plot/lib/widget/thread_carousel.dart apps/plot/test/widget/thread_carousel_test.dart
git commit -m "feat(app): ThreadCarousel swipe-between-threads PageView with preview neighbors"
```

---

## Task 4: iOS left-edge back zone

Verify (and harden) that a drag starting in the reserved left-edge strip does
**not** drive the carousel, so the iOS system edge-swipe-back can return to the
list. A drag starting outside the strip drives the carousel normally.

**Files:**
- Modify: `apps/plot/lib/widget/thread_carousel.dart` (only if the test reveals a gap; the Task 3 implementation already includes the `Listener`)
- Test: `apps/plot/test/widget/thread_carousel_test.dart` (add cases)

- [ ] **Step 1: Write the failing tests**

Append to `apps/plot/test/widget/thread_carousel_test.dart` inside `main()`:

```dart
  testWidgets('drag starting in the left-edge zone does not open a neighbor',
      (tester) async {
    final c = mk('center');
    final p = mk('prev');
    final opened = <Thread>[];
    await tester.pumpWidget(host(
      center: c,
      previous: p,
      opened: opened,
      reserveLeftEdgeBackZone: true,
    ));

    // Start the pointer at x=10 (inside the 20px edge zone) and drag right.
    final gesture = await tester.startGesture(const Offset(10, 400));
    await tester.pump(); // let onPointerDown freeze the PageView
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(opened, isEmpty); // edge drag was reserved for back, not carousel
  });

  testWidgets('drag starting outside the edge zone still opens a neighbor',
      (tester) async {
    final c = mk('center');
    final p = mk('prev');
    final opened = <Thread>[];
    await tester.pumpWidget(host(
      center: c,
      previous: p,
      opened: opened,
      reserveLeftEdgeBackZone: true,
    ));

    // Start the pointer at x=200 (well outside the edge zone) and drag right.
    final gesture = await tester.startGesture(const Offset(200, 400));
    await tester.pump();
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(opened.map((t) => t.id), [p.id]);
  });
```

- [ ] **Step 2: Run tests to verify status**

Run: `cd apps/plot && flutter test test/widget/thread_carousel_test.dart`
Expected: both new tests PASS with the Task 3 implementation (the `Listener` freezes the PageView via `NeverScrollableScrollPhysics` when the pointer-down lands in the edge zone). If the "outside the edge zone" case fails to open (the drag distance didn't cross the settle threshold), increase the `moveBy` distance to `Offset(350, 0)`.

- [ ] **Step 3: Harden only if needed**

If the "edge zone" test fails (carousel still moved), the physics-toggle lost the race with the scrollable claiming the drag. Replace the freeze mechanism with a left-edge exclusion overlay: wrap `pageView` in a `Stack` and add, above it, a left-aligned `SizedBox(width: widget.edgeZoneWidth)` carrying a `RawGestureDetector` with a `HorizontalDragGestureRecognizer` whose callbacks are empty — but configured so the **route's** back recognizer wins. Concretely, prefer the simplest working option and document which one you used:
- (a) physics-toggle (Task 3 default), or
- (b) a `MediaQuery` `gestureSettings`-aware exclusion, or
- (c) reducing the PageView hit region with a left `Padding` of `edgeZoneWidth` **only when** `reserveLeftEdgeBackZone` is true (accepts a 20px left gutter on iOS).

Only change the implementation if Step 2 actually failed; otherwise leave Task 3's code as is. Note the final mechanism in a code comment.

- [ ] **Step 4: Re-run the full carousel test file**

Run: `cd apps/plot && flutter test test/widget/thread_carousel_test.dart`
Expected: PASS (all 7 tests).

- [ ] **Step 5: Analyze and commit**

```bash
cd apps/plot && flutter analyze lib/widget/thread_carousel.dart test/widget/thread_carousel_test.dart
git add apps/plot/lib/widget/thread_carousel.dart apps/plot/test/widget/thread_carousel_test.dart
git commit -m "feat(app): reserve iOS left-edge back zone in ThreadCarousel"
```

---

## Task 5: Wire the carousel into `ThreadPage`

Extract today's live-thread construction into `_buildLiveThread(ThreadId)`. In
`wrappedRoute`, on desktop/web return it unchanged; on iOS/Android wrap it in
the carousel, computing neighbors from `PriorityBloc.getActivityFeedItem`.

**Files:**
- Modify: `apps/plot/lib/page/thread.dart:31-58` (the `wrappedRoute` method) and add a private `_buildLiveThread`.

**Interfaces:**
- Consumes: `ThreadCarousel`, `ThreadPreview`, `shouldUseThreadCarousel`, `threadFromAgendaItem`, `PriorityBloc.getActivityFeedItem`, `PriorityBloc.setThread`.

- [ ] **Step 1: Add imports**

In `apps/plot/lib/page/thread.dart`, add to the local-import group:

```dart
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:plot/util/thread_carousel_nav.dart';
import 'package:plot/widget/thread_carousel.dart';
import 'package:plot/widget/thread_preview.dart';
```

(If `package:flutter/foundation.dart` is already imported transitively, ensure `kIsWeb`, `defaultTargetPlatform`, and `TargetPlatform` are available; `package:flutter/widgets.dart` re-exports them, so the explicit `show` may be unnecessary — drop it if `flutter analyze` flags a duplicate.)

- [ ] **Step 2: Extract `_buildLiveThread` and branch `wrappedRoute`**

Replace the body of `wrappedRoute` (current lines 31-57) so the valid-thread path delegates to `_buildLiveThread`, and add the carousel branch. The invalid-threadId redirect (lines 34-42) is unchanged.

```dart
  @override
  Widget wrappedRoute(BuildContext context) {
    final threadId = this.threadId;
    if (threadId == null) {
      // Invalid base58 thread id (e.g. /p/<pid>/login). Redirect to home
      // instead of crashing in the parser.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        context.router.replaceAll([const RootRoute()]);
      });
      return const SizedBox.shrink();
    }

    if (!shouldUseThreadCarousel(
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
    )) {
      return _buildLiveThread(threadId);
    }

    // iOS / Android: wrap the live thread in the swipe carousel. Neighbors are
    // resolved from the same feed the thread was opened from. Swiping promotes
    // a neighbor via setThread only (no route push), so the back stack stays a
    // single ThreadRoute and Back returns to the list.
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        final priorityBloc = context.read<PriorityBloc>();
        final centerId = state.thread?.id ?? threadId;
        // Only offer neighbors once the bloc is aligned to this thread;
        // otherwise getActivityFeedItem keys off a stale/absent selection.
        final aligned = state.thread?.id == centerId;
        final previous = aligned
            ? threadFromAgendaItem(priorityBloc.getActivityFeedItem(-1))
            : null;
        final next = aligned
            ? threadFromAgendaItem(priorityBloc.getActivityFeedItem(1))
            : null;
        return ThreadCarousel(
          centerThreadId: centerId,
          previous: previous,
          next: next,
          centerBuilder: _buildLiveThread,
          previewBuilder: (thread) => ThreadPreview(thread: thread),
          onOpenNeighbor: (thread) =>
              context.read<PriorityBloc>().setThread(thread),
          reserveLeftEdgeBackZone:
              !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS,
        );
      },
    );
  }

  /// Builds the single live thread view for [id] — the existing thread page,
  /// unchanged. Used directly on desktop/web and as the carousel center on
  /// mobile. Keyed by id at the call site (see [ThreadCarousel]) so only one
  /// ThreadBloc is ever mounted and it is preserved across feed rebuilds.
  Widget _buildLiveThread(ThreadId id) {
    return ThreadBlocProvider(
      threadId: id,
      thread: null, // Let the bloc load the thread
      child: BlocConsumer<ThreadBloc, ThreadState>(
        listener: (context, state) {
          context.read<PriorityBloc>().setThread(state.thread);
        },
        listenWhen: (previous, current) =>
            previous.thread.id != current.thread.id,
        builder: (context, state) {
          return _ThreadPageContent();
        },
      ),
    );
  }
```

Note: `wrappedRoute` and `_buildLiveThread` are members of `ThreadPage`. Confirm `PriorityState` is imported (it comes via `package:plot/state/priority.dart`, already imported at line 10). `PriorityBloc.getActivityFeedItem` and `setThread` are defined in `state/priority.dart`.

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze lib/page/thread.dart`
Expected: no errors. Fix any (e.g. unused `show` clause, missing import).

- [ ] **Step 4: Run the existing thread page / state test suites to catch regressions**

Run: `cd apps/plot && flutter test test/page test/state/agenda_builder_test.dart test/widget/thread_carousel_test.dart test/widget/thread_preview_test.dart test/util/thread_carousel_nav_test.dart`
Expected: PASS (no regressions in page/state tests; new tests green).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/page/thread.dart
git commit -m "feat(app): swipe between threads on iOS/Android via ThreadCarousel"
```

---

## Task 6: Docs, full lint, and on-device verification

**Files:**
- Modify: `apps/plot/docs/updates.md`

- [ ] **Step 1: Add the user-facing updates bullet**

In `apps/plot/docs/updates.md`, under `## Next release`, add to the existing `### Threads`-style section if one fits, otherwise add the bullet under `### Fixes` is wrong for a feature — create a `### Threads` section above `### Fixes`:

```markdown
### Threads

- On phones and tablets, swipe left or right while reading a thread to jump to the next or previous one in your list — like flipping through email.
```

If a `## Next release` heading does not exist (the last one was just stamped to a version), create a fresh `## Next release` at the very top above the most recent version heading, then add the section.

- [ ] **Step 2: Full analyze**

Run: `cd apps/plot && flutter analyze`
Expected: clean (no new warnings/errors from this change).

- [ ] **Step 3: Run the full new + adjacent test set once more**

Run: `cd apps/plot && flutter test test/util/thread_carousel_nav_test.dart test/widget/thread_preview_test.dart test/widget/thread_carousel_test.dart`
Expected: PASS.

- [ ] **Step 4: On-device verification (manual, via the `run-app` skill)**

The gesture feel and the two known polish risks can only be confirmed on a real touch target. Invoke the `run-app` skill and verify on an iOS simulator/device (and an Android one if available):

1. Open a thread from the activity feed. Swipe left → next thread becomes live; swipe right → previous thread becomes live.
2. The incoming page shows the read-only preview (title + snippet) during the drag, then becomes the full live thread after it settles (**watch for a recenter flicker** when the promoted page snaps to center — if present, refine by switching the recenter from settle→`jumpToPage` to `animateToPage`→model-swap, or a virtualized index map; note the outcome).
3. Only the thread you land on is marked read — neighbors you merely drag past stay unread (check the unread dot in the feed after backing out).
4. At the first thread, swiping right rubber-bands (no previous). At the last loaded thread, swiping left rubber-bands.
5. **iOS edge-back:** a swipe starting at the very left edge returns to the list; a swipe starting elsewhere drives the carousel. If the edge gesture and carousel conflict, apply the Task 4 Step 3 fallback and re-verify.
6. Open a thread via a notification / `/t/` deep link (no list context) → no swipe between threads (inert), single thread renders as before.
7. Back button / Android back returns to the list (not to a previously-swiped thread), and swiping through many threads does not stack up Back presses.
8. Desktop/web unchanged: keyboard up/down still navigates; no carousel.

- [ ] **Step 5: Commit docs**

```bash
git add apps/plot/docs/updates.md
git commit -m "docs(app): note swipe-between-threads in updates"
```

- [ ] **Step 6: Finalize**

Run the `/finalize` checklist (lint, backwards-compat, error capture, docs, public submodule). This change is app-only, no schema, no new catch blocks, no public submodule — but run it to confirm.

---

## Self-Review

**Spec coverage:**
- Finger-following carousel → Task 3 (`PageView` with live center + previews). ✓
- iOS + Android only → Task 1 `shouldUseThreadCarousel` + Task 5 gate. ✓
- Left-edge back zone → Task 4. ✓
- Lightweight preview, promote on settle → Task 2 `ThreadPreview` + Task 3 `onOpenNeighbor`/recenter. ✓
- Direction (left=next, right=previous) → Task 3 `_onPageChanged`. ✓
- Boundaries rubber-band + no-context inert → Task 3 dynamic page list (null neighbor = no page) + Task 5 `aligned`/null neighbors. ✓
- Only-center marked read → previews never mount `_ThreadPageContent`; Task 5 keeps a single keyed live center; verified in Task 6 Step 4.3. ✓
- No back-stack growth, Back→list → Task 5 `setThread`-only (no route push); verified Task 6 Step 4.7. ✓
- Reuse `getActivityFeedItem` → Task 5. ✓
- Tests → Tasks 1–4 unit/widget; gesture/visual polish → Task 6 manual. ✓
- `docs/updates.md` → Task 6. ✓

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to" — each step has concrete code or a concrete command. The `ThreadPreview` styling and the edge-zone fallback include explicit verify-against-codebase notes, not placeholders. ✓

**Type consistency:** `centerThreadId: ThreadId`, `previous/next: Thread?`, `onOpenNeighbor: void Function(Thread)`, `centerBuilder: Widget Function(ThreadId)`, `previewBuilder: Widget Function(Thread)` are identical across Task 3 (definition), Task 5 (call site), and the tests. `threadFromAgendaItem`/`shouldUseThreadCarousel` signatures match between Task 1 and Task 5. ✓

## Known Risks (carried to Task 6 manual verification)

1. **Recenter flicker on promotion** — the settle→`jumpToPage(_centerIndex)` recenter may show the post-promotion neighbor preview for one frame. Mitigation options documented in Task 6 Step 4.2. Core behavior is correct and tested regardless.
2. **iOS edge-zone arena race** — the physics-toggle on pointer-down may lose the gesture-arena race with the scrollable on some devices. Task 4 includes a hardening fallback (left-edge exclusion / gutter) gated on the test/device actually failing.

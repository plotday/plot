# Pin to Thread — Restore Top-of-Thread Display — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render user-pinned bookmark links as rows at the top of a thread (open / edit / unpin), restoring the display deleted in commit `e896b5a96`.

**Architecture:** A new focused `PinnedLinkRow` widget (`apps/plot/lib/widget/pinned_link_row.dart`) renders one bookmark `Link`. A pure helper `pinnedBookmarkLinks(...)` filters the thread's canonical links to bookmarks (no connector type config). `thread.dart` maps the filtered links into the slot above the notes list. The two store methods the row uses (`Link.updateTitleAndUrl`, `Link.unpinFromThread`) already exist as currently-dead code.

**Tech Stack:** Flutter, forui widgets, Drift (SQLite) store, `url_launcher`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-06-24-pin-to-thread-display-design.md`

## Global Constraints

- UI library: **forui** + `flutter/widgets.dart` only. Never import `flutter/material.dart`.
- UI text is **sentence case** ("Edit link", "Unpin from thread").
- Pointer cursor (`SystemMouseCursors.click`) is permitted **only** for true links that navigate to external content — the pinned-bookmark row qualifies; the `…` menu button uses `SystemMouseCursors.basic`.
- **Bloc only in pages**, not widgets. `thread.dart` (the page) does the link filtering and passes a plain `Link` to the widget.
- Capture only **unexpected** errors with `captureException`. `launchUrl` failures and unparseable URLs are expected/user-facing — guard and return, no capture.
- **No** database/schema/Drift/migration/sync/API changes. Reuse `Link.updateTitleAndUrl` (`link.dart:659`) and `Link.unpinFromThread` (`link.dart:680`) unchanged.
- The bookmark discriminator is `link.getTypeConfig() == null && link.sourceUrl != null` (same "user-editable" test the deleted code used). Connector-managed links (type config present) are **not** rendered as rows — they keep the header treatment (`PrimaryLinkHeaderActions`), which is untouched.

---

### Task 1: `PinnedLinkRow` widget + `pinnedBookmarkLinks` helper

**Files:**
- Create: `apps/plot/lib/widget/pinned_link_row.dart`
- Test: `apps/plot/test/widget/pinned_link_row_test.dart`

**Interfaces:**
- Consumes: `Link` (from `package:plot/store/store.dart`) — getters `title` (`String?`), `sourceUrl` (`String?`), `logoForBrightness(Brightness)` (`String?`), `getTypeConfig()` (`LinkTypeConfig?`); static methods `Link.updateTitleAndUrl(Link, {required String? title, required String url})`, `Link.unpinFromThread(Link)`. `EditLinkModal({required String initialTitle, required String initialUrl})` with `Future<EditLinkResult?> run(BuildContext)` where `EditLinkResult` has `String title` and `String url`.
- Produces:
  - `class PinnedLinkRow extends StatefulWidget` with `const PinnedLinkRow({required Link link, Key? key})`.
  - `Iterable<Link> pinnedBookmarkLinks(Iterable<Link> links)` — top-level function.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/widget/pinned_link_row_test.dart`:

```dart
library;

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' show FTheme;
import 'package:injector/injector.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/edit_link_modal.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/pinned_link_row.dart';

// Records launched URLs so the row's tap-to-open behaviour is observable.
class _FakeUrlLauncher extends Fake
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  final launched = <String>[];

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

Widget host(Widget child) {
  final scheme = ColourSchemeData(
    themeColor: const ThemeColor(0),
    brightness: Brightness.light,
  );
  return Provider<ColourSchemeData>.value(
    value: scheme,
    child: Builder(
      builder: (context) => FTheme(
        data: buildTheme(context, scheme),
        child: MediaQuery(
          data: const MediaQueryData(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Overlay(
              initialEntries: [OverlayEntry(builder: (_) => child)],
            ),
          ),
        ),
      ),
    ),
  );
}

// Inserts a user-pinned bookmark (no createdBy/type → getTypeConfig() == null)
// and returns the wrapped Link via the canonical watch.
Future<Link> _insertBookmark(
  Store store,
  ThreadId threadId, {
  String? sourceUrl = 'https://example.com',
  String title = 'Example',
}) async {
  await store.into(store.links).insert(
        LinksCompanion.insert(
          id: Value(Uuid.generate()),
          sourceCreatedAt: DateTime(2026),
          createdAt: Value(DateTime(2026)),
          threadId: Value(threadId),
          sourceUrl: Value(sourceUrl),
          title: Value(title),
          priority: const Value(0),
          noteScoped: const Value(false),
        ),
      );
  final links = await Link.watchForThread(threadId).first;
  return links.first;
}

void main() {
  late Store store;
  late _FakeUrlLauncher launcher;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
    TwistInstance.clearCache();
    Channel.populateCache(const []);
    launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
  });

  tearDown(() async {
    TwistInstance.clearCache();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  testWidgets('renders the link title', (tester) async {
    final threadId = Uuid.generate();
    final link = await _insertBookmark(store, threadId, title: 'My bookmark');
    await tester.pumpWidget(host(PinnedLinkRow(link: link)));
    expect(find.text('My bookmark'), findsOneWidget);
  });

  testWidgets('tapping the row opens the URL externally', (tester) async {
    final threadId = Uuid.generate();
    final link =
        await _insertBookmark(store, threadId, sourceUrl: 'https://plot.day');
    await tester.pumpWidget(host(PinnedLinkRow(link: link)));
    await tester.tap(find.text('Example'));
    await tester.pump();
    expect(launcher.launched, contains('https://plot.day'));
  });

  testWidgets('the menu exposes Edit and Unpin', (tester) async {
    final threadId = Uuid.generate();
    final link = await _insertBookmark(store, threadId);
    await tester.pumpWidget(host(PinnedLinkRow(link: link)));
    await tester.tap(find.byIcon(PlotIcon.more));
    await tester.pumpAndSettle();
    expect(find.text('Edit link'), findsOneWidget);
    expect(find.text('Unpin from thread'), findsOneWidget);
  });

  testWidgets('Unpin detaches the link from the thread', (tester) async {
    final threadId = Uuid.generate();
    final link = await _insertBookmark(store, threadId);
    await tester.pumpWidget(host(PinnedLinkRow(link: link)));
    await tester.tap(find.byIcon(PlotIcon.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpin from thread'));
    await tester.pump();
    final rows = await store.select(store.links).get();
    expect(rows.single.threadId, isNull);
  });

  testWidgets('Edit opens the EditLinkModal', (tester) async {
    final threadId = Uuid.generate();
    final link = await _insertBookmark(store, threadId);
    await tester.pumpWidget(host(PinnedLinkRow(link: link)));
    await tester.tap(find.byIcon(PlotIcon.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit link'));
    await tester.pumpAndSettle();
    expect(find.byType(EditLinkModal), findsOneWidget);
  });

  test('pinnedBookmarkLinks includes bookmarks, excludes URL-less links',
      () async {
    final threadId = Uuid.generate();
    final bookmark = await _insertBookmark(store, threadId);
    final urlless = await _insertBookmark(
      Store.get,
      threadId,
      sourceUrl: null,
      title: 'no url',
    );
    final result = pinnedBookmarkLinks([bookmark, urlless]).toList();
    expect(result.length, 1);
    expect(result.single.sourceUrl, 'https://example.com');
  });

  test('pinnedBookmarkLinks excludes connector-managed links', () async {
    // A cached source twist with a declared link type makes getTypeConfig()
    // non-null for a link that carries its ptId + type.
    final ptId = Uuid.generate();
    await store.into(store.twistInstances).insert(
          TwistInstancesCompanion.insert(
            id: Value(ptId),
            twistId: BigInt.from(100),
            twistEnvironment: 'test',
            name: 'Linear',
            config: const {},
            createdAt: Value(DateTime(2026)),
            updatedAt: Value(DateTime(2026)),
            isSource: const Value(true),
            linkTypes: const Value('[{"type":"issue","label":"Issue"}]'),
          ),
        );
    await TwistInstance.get(); // populates the synchronous cache

    final threadId = Uuid.generate();
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(Uuid.generate()),
            sourceCreatedAt: DateTime(2026),
            createdAt: Value(DateTime(2026)),
            threadId: Value(threadId),
            sourceUrl: const Value('https://linear.app/x'),
            title: const Value('PLOT-1'),
            createdBy: Value(ptId),
            type: const Value('issue'),
            priority: const Value(0),
            noteScoped: const Value(false),
          ),
        );
    final links = await Link.watchForThread(threadId).first;
    expect(links.single.getTypeConfig(), isNotNull); // it IS a connector link
    expect(pinnedBookmarkLinks(links), isEmpty);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/pinned_link_row_test.dart`
Expected: FAIL — `pinned_link_row.dart` does not exist / `PinnedLinkRow` and `pinnedBookmarkLinks` are undefined (compile error).

- [ ] **Step 3: Write the widget + helper**

Create `apps/plot/lib/widget/pinned_link_row.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart' show darkenTheme;
import 'package:plot/widget/edit_link_modal.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/logo_image.dart';

/// Filters a thread's canonical links to the user-pinned bookmarks that render
/// as [PinnedLinkRow]s: links with no connector type config and a source URL.
/// Connector-managed links (a non-null [Link.getTypeConfig]) are excluded —
/// they keep the header treatment (PrimaryLinkHeaderActions).
Iterable<Link> pinnedBookmarkLinks(Iterable<Link> links) =>
    links.where((l) => l.getTypeConfig() == null && l.sourceUrl != null);

/// A compact row for a user-pinned bookmark [Link], rendered above the notes
/// list at the top of a thread. Shows the source logo + title; tapping opens
/// the URL externally. A trailing "…" menu offers Edit link and Unpin from
/// thread.
class PinnedLinkRow extends StatefulWidget {
  const PinnedLinkRow({required this.link, super.key});

  final Link link;

  @override
  State<PinnedLinkRow> createState() => _PinnedLinkRowState();
}

class _PinnedLinkRowState extends State<PinnedLinkRow> {
  bool _hovered = false;

  Future<void> _open() async {
    final url = widget.link.sourceUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final hasUrl = link.sourceUrl != null;
    return FTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) {
          final linkLogo = link.logoForBrightness(context.colour.brightness);
          return GestureDetector(
            onTap: hasUrl ? _open : null,
            child: MouseRegion(
              cursor: hasUrl
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.theme.colors.background,
                  border: Border(
                    bottom: BorderSide(
                      color: context.theme.colors.border,
                      width: 0.5,
                    ),
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.isMultiPanel
                        ? 20.0
                        : context.contentPaddingH,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      if (linkLogo != null)
                        LogoImage(
                          url: linkLogo,
                          fallback: const Icon(PlotIcon.link, size: 14),
                        )
                      else
                        const Icon(PlotIcon.link, size: 14),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          link.title ?? '',
                          style: context.theme.typography.sm.copyWith(
                            color: _hovered
                                ? context.theme.colors.foreground
                                : context.theme.colors.foreground
                                      .withValues(alpha: 0.7),
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _PinnedLinkMenu(link: link),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// "…" overlay menu for a pinned bookmark row: Edit link + Unpin from thread.
/// Mirrors the structure of `_NoteLinkMenu` in note_action.dart.
class _PinnedLinkMenu extends StatefulWidget {
  const _PinnedLinkMenu({required this.link});

  final Link link;

  @override
  State<_PinnedLinkMenu> createState() => _PinnedLinkMenuState();
}

class _PinnedLinkMenuState extends State<_PinnedLinkMenu> {
  final _controller = OverlayPortalController();

  @override
  Widget build(BuildContext context) {
    final style = context.theme.popoverMenuStyle;

    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: (overlayContext) {
        final buttonBox = this.context.findRenderObject() as RenderBox;
        final overlay =
            Overlay.of(overlayContext).context.findRenderObject() as RenderBox;
        final position = buttonBox.localToGlobal(
          Offset(buttonBox.size.width, buttonBox.size.height),
          ancestor: overlay,
        );

        return Positioned(
          top: position.dy,
          right: overlay.size.width - position.dx,
          child: TapRegion(
            onTapOutside: (_) => _controller.hide(),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: style.maxWidth),
              child: DecoratedBox(
                decoration: style.decoration,
                child: FInheritedItemData(
                  child: FItemGroup.merge(
                    style: style.itemGroupStyle,
                    divider: FItemDivider.full,
                    children: [FItemGroup(children: _buildMenuItems())],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: GestureDetector(
        onTap: () {
          if (_controller.isShowing) {
            _controller.hide();
          } else {
            _controller.show();
          }
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Icon(
              PlotIcon.more,
              size: 14,
              color: context.theme.colors.foreground.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }

  List<FItem> _buildMenuItems() {
    return [
      FItem(
        title: const Text('Edit link'),
        onPress: () {
          _controller.hide();
          _editLink();
        },
      ),
      FItem(
        title: const Text('Unpin from thread'),
        onPress: () {
          _controller.hide();
          Link.unpinFromThread(widget.link);
        },
      ),
    ];
  }

  Future<void> _editLink() async {
    final result = await EditLinkModal(
      initialTitle: widget.link.title ?? '',
      initialUrl: widget.link.sourceUrl ?? '',
    ).run(context);
    if (result == null) return;
    if (result.title == widget.link.title && result.url == widget.link.sourceUrl) {
      return;
    }
    await Link.updateTitleAndUrl(
      widget.link,
      title: result.title.isEmpty ? null : result.title,
      url: result.url,
    );
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/pinned_link_row_test.dart`
Expected: PASS (all 7 tests).

If `find.byIcon(PlotIcon.more)` matches more than one icon, scope the tap with `find.descendant(of: find.byType(PinnedLinkRow), matching: find.byIcon(PlotIcon.more))`.

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/pinned_link_row.dart apps/plot/test/widget/pinned_link_row_test.dart
git commit -m "feat(thread): add PinnedLinkRow for user-pinned bookmark links

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Render pinned bookmarks above the notes list in `thread.dart`

**Files:**
- Modify: `apps/plot/lib/page/thread.dart` (add import; insert the mapped rows at line ~754, between `_ThreadFilterBar` and the notes `Flexible`)

**Interfaces:**
- Consumes: `pinnedBookmarkLinks(Iterable<Link>)` and `PinnedLinkRow` from `package:plot/widget/pinned_link_row.dart`; `state.links` (a `List<Link>` of canonical links, already populated by `Link.watchForThread` at `thread.dart:493`).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Add the import**

In `apps/plot/lib/page/thread.dart`, add to the import block (next to the other `package:plot/widget/...` imports, e.g. after the `primary_link_header_actions.dart` import):

```dart
import 'package:plot/widget/pinned_link_row.dart';
```

- [ ] **Step 2: Insert the rows in the Column**

In `apps/plot/lib/page/thread.dart`, the `Column` children currently read (around line 749-757):

```dart
                            if (layoutStateForPanels.multiPanel)
                              _ThreadActionsRow(thread: state.thread),
                            if (state.threadNoteId != null)
                              _ThreadFilterBar(
                                threadNoteId: state.threadNoteId!,
                              ),
                            Flexible(
                              flex: 1,
                              fit: FlexFit.tight,
```

Insert the pinned-bookmark rows between the filter bar and the `Flexible`:

```dart
                            if (layoutStateForPanels.multiPanel)
                              _ThreadActionsRow(thread: state.thread),
                            if (state.threadNoteId != null)
                              _ThreadFilterBar(
                                threadNoteId: state.threadNoteId!,
                              ),
                            ...pinnedBookmarkLinks(state.links).map(
                              (link) => PinnedLinkRow(link: link),
                            ),
                            Flexible(
                              flex: 1,
                              fit: FlexFit.tight,
```

- [ ] **Step 3: Verify the existing tests + analyzer still pass**

Run: `cd apps/plot && flutter test test/widget/pinned_link_row_test.dart && flutter analyze lib/page/thread.dart lib/widget/pinned_link_row.dart`
Expected: tests PASS; analyzer reports **no issues** for both files.

- [ ] **Step 4: Manual verification (run-app)**

The page-level render path has no cheap automated test (it requires the full `ThreadBloc` + provider stack); the logic it adds is the `pinnedBookmarkLinks` predicate, already unit-tested in Task 1. Verify the wiring by hand:

Use the `run-app` skill to launch the macOS app. In a thread, open the `…` menu on a link attached to a note and choose **Pin to thread**. Confirm:
1. A row with the link's title appears at the top of the thread, above the notes.
2. Clicking the row opens the URL externally.
3. The row's `…` menu offers **Edit link** and **Unpin from thread**; Unpin removes the row.
4. A thread backed by a connector link (e.g. a calendar event) shows **no** such row (the header join/status treatment is unchanged).

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/page/thread.dart
git commit -m "feat(thread): render pinned bookmark rows above the notes list

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Documentation + finalize

**Files:**
- Modify: `docs/updates.md`

**Interfaces:** none.

- [ ] **Step 1: Add a user-facing update note**

In `docs/updates.md`, under the `## Next release` heading, add (or extend an existing thread/links `###` section — create `### Threads` above `### Fixes` if none fits) a bullet:

```markdown
- Links you pin to a thread now appear at the top of the thread again, and you can open, edit, or unpin them.
```

If there is no `## Next release` heading (the top is a stamped `## <version> — <date>`), create a fresh `## Next release` section above it first, then add the `### Threads` section and bullet under it.

- [ ] **Step 2: Run the finalize checklist**

Invoke the `/finalize` skill (or run its checks manually):

Run: `cd apps/plot && flutter analyze`
Expected: **No issues found.**

Confirm: no new `catch` blocks were added (the row guards `launchUrl` without catching), no `public/` submodule changes, no schema/migration changes.

- [ ] **Step 3: Run the full widget test once more**

Run: `cd apps/plot && flutter test test/widget/pinned_link_row_test.dart`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot
git add docs/updates.md
git commit -m "docs: note restored pinned-link display in updates

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Goal (render user-pinned bookmarks as rows) → Task 1 (widget) + Task 2 (wiring). ✓
- Bookmark scope / predicate `getTypeConfig() == null && sourceUrl != null` → `pinnedBookmarkLinks`, Task 1; tested (inclusion, URL-less exclusion, connector exclusion). ✓
- Row visual (logo + title, darkenTheme band, bottom border, padding) → Task 1 widget code. ✓
- Tap opens URL externally, pointer cursor → Task 1 `_open` + `MouseRegion`; tested. ✓
- Edit + Unpin menu reusing `updateTitleAndUrl` / `unpinFromThread` → Task 1 `_PinnedLinkMenu`; tested (menu items, unpin detaches, edit opens modal). ✓
- Placement above notes, page does filtering → Task 2 insertion at the old slot. ✓
- Header (`PrimaryLinkHeaderActions`) untouched; connector links excluded → no header change in any task; connector-exclusion tested. ✓
- No schema/sync/API changes; capture only unexpected errors → Global Constraints + Task 3 finalize check. ✓
- `docs/updates.md` bullet → Task 3. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; every run step shows the command and expected result. ✓

**Type consistency:** `PinnedLinkRow({required Link link})`, `pinnedBookmarkLinks(Iterable<Link>) → Iterable<Link>`, `Link.updateTitleAndUrl(Link, {required String? title, required String url})`, `Link.unpinFromThread(Link)`, `EditLinkResult{title,url}` are used identically across the widget, its tests, and the wiring. ✓

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
import 'package:plot/widget/modal.dart';
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
          // >760px => multi-panel => Modal.show uses showFDialog (which, like
          // showFSheet, needs a Navigator ancestor). Mirrors the host in
          // modal_pop_for_swap_test.dart.
          data: const MediaQueryData(size: Size(1200, 800)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            // Navigator -> ModalProvider so EditLinkModal.run() (Modal.show ->
            // ModalProvider.of -> showFDialog -> Navigator.of) resolves; the
            // child renders inside the provider's Overlay.
            child: Navigator(
              onGenerateRoute: (_) => PageRouteBuilder<void>(
                pageBuilder: (_, _, _) => ModalProvider(
                  child: Overlay(
                    initialEntries: [OverlayEntry(builder: (_) => child)],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

// Inserts a user-pinned bookmark (no createdBy/type → getTypeConfig() == null)
// and returns the wrapped Link. NOTE: this uses a one-shot select rather than
// `Link.watchForThread().first`. A Drift `.watch()` stream emits via real async
// scheduling that the `testWidgets` FakeAsync zone never pumps, so awaiting the
// stream's `.first` inside a `testWidgets` body deadlocks. A one-shot `get()`
// returns the same rows and resolves on the real event loop.
Future<Link> _insertBookmark(
  Store store,
  ThreadId threadId, {
  String? sourceUrl = 'https://example.com',
  String title = 'Example',
}) async {
  final id = Uuid.generate();
  await store.into(store.links).insert(
        LinksCompanion.insert(
          id: Value(id),
          sourceCreatedAt: DateTime(2026),
          createdAt: Value(DateTime(2026)),
          threadId: Value(threadId),
          sourceUrl: Value(sourceUrl),
          title: Value(title),
          priority: const Value(0),
          noteScoped: const Value(false),
        ),
      );
  // Fetch by the inserted id, not `rows.first` for the thread — two bookmarks
  // can share a thread (the URL-less filter test inserts both into one), so a
  // thread-scoped query would ambiguously return the wrong row.
  final row = await (store.select(store.links)
        ..where((l) => l.id.equals(id.toBytes())))
      .getSingle();
  return Link(row);
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
    // pumpAndSettle drains forui's tappable animation timers (FTappable), which
    // otherwise leave "a Timer is still pending" at teardown.
    await tester.pumpAndSettle();
    // `Link.unpinFromThread` is fire-and-forget from the menu's onPress, and its
    // write (Store.save → add) plus this select are real Futures the testWidgets
    // FakeAsync zone never pumps. Drain them on the real event loop (and poll
    // briefly so the async write lands before we assert).
    final threadIdAfter = await tester.runAsync(() async {
      for (var i = 0; i < 50; i++) {
        final rows = await store.select(store.links).get();
        if (rows.single.threadId == null) return rows.single.threadId;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return (await store.select(store.links).get()).single.threadId;
    });
    expect(threadIdAfter, isNull);
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

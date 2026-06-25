import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/command/filter.dart';
import 'package:plot/store/store.dart';

/// Plot-created threads carry the well-known Plot icon URL
/// (`https://plot.day/assets/plot-icon.svg`, the `@plot.app` priority's
/// `default_thread_icon`). The source filter must surface these under their
/// own "Plot" chip rather than folding them into the generic "Link" bucket
/// alongside pasted-link favicons. See
/// [Thread.watchIconCountsForPriority].
void main() {
  late Store store;

  const plotIconUrl = 'https://plot.day/assets/plot-icon.svg';
  final priorityId = Uuid.generate();

  setUp(() async {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
    await store.into(store.priorities).insert(
          PrioritiesCompanion(
            id: Value(priorityId),
            title: const Value('Inbox'),
            createdBy: Value(Uuid.generate()),
            path: Value(Path('inbox')),
            order: const Value(Order(0)),
            isInbox: const Value(true),
            unread: const Value(false),
            role: const Value('member'),
          ),
        );
  });

  tearDown(() async {
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  Future<Uuid> insertThread(String? icon) async {
    final id = Uuid.generate();
    await store.into(store.threads).insert(
          ThreadsCompanion(
            id: Value(id),
            priorityId: Value(priorityId),
            contacts: Value([Uuid.generate()]),
            draft: const Value(false),
            unread: const Value(false),
            importance: const Value(0),
            createdAt: Value(DateTime.now()),
            title: const Value('t'),
            icon: Value(icon),
          ),
        );
    return id;
  }

  test('Plot icon threads form a separate bucket from pasted links', () async {
    await insertThread(plotIconUrl);
    await insertThread(plotIconUrl);
    await insertThread('https://example.com/favicon.ico'); // pasted link
    await insertThread('link'); // literal link icon
    await insertThread('idea'); // built-in subtype

    final counts = await Thread.watchIconCountsForPriority().first;
    final byKey = {for (final (key, n) in counts) key: n};

    // Plot threads are their own bucket, not part of "link".
    expect(byKey['plot'], 2, reason: 'Plot icon URL should bucket as "plot"');
    // The link bucket only has the genuine pasted link + literal 'link'.
    expect(byKey['link'], 2, reason: 'Plot threads must not inflate "link"');
    expect(byKey['idea'], 1);
    // The raw Plot URL must not leak through as its own row.
    expect(byKey.containsKey(plotIconUrl), isFalse);
  });

  test('the "plot" filter matches only Plot threads; "link" excludes them',
      () async {
    final plotA = await insertThread(plotIconUrl);
    final plotB = await insertThread(plotIconUrl);
    final favicon = await insertThread('https://example.com/favicon.ico');
    final literal = await insertThread('link');

    final plotMatches = await Thread.get(iconFilter: ['plot']);
    expect(
      plotMatches.map((t) => t.id).toSet(),
      {plotA, plotB},
      reason: 'the "plot" chip matches only Plot-icon threads',
    );

    final linkMatches = await Thread.get(iconFilter: ['link']);
    expect(
      linkMatches.map((t) => t.id).toSet(),
      {favicon, literal},
      reason: 'the "link" chip must not pull in Plot threads',
    );
  });

  testWidgets('the "plot" chip shows the Plot name and logo', (tester) async {
    late ToggleIconFilter plotChip;
    late ToggleIconFilter linkChip;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          plotChip = ToggleIconFilter('plot', context: context);
          linkChip = ToggleIconFilter(
            'https://example.com/favicon.ico',
            context: context,
          );
          return const SizedBox();
        },
      ),
    );

    expect(plotChip.title, 'Plot');
    expect(plotChip.logoUrl, plotIconUrl);
    expect(plotChip.hasLogo, isTrue);

    // A genuine pasted-link favicon is still described as "Link".
    expect(linkChip.title, 'Link');
  });
}

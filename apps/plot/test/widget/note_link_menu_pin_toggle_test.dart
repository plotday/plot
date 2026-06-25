/// Tests `matchingPinnedLink`, which drives the note-attached link "…" menu's
/// "Pin to thread" / "Unpin from thread" toggle: it returns the canonical
/// thread link whose source URL matches the note link (so the menu offers
/// Unpin), or null when the link is not pinned (so the menu offers Pin).
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/note_action.dart';

void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
  });

  tearDown(() async {
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  Future<void> insertCanonical(ThreadId threadId, String url) async {
    await store
        .into(store.links)
        .insert(
          LinksCompanion.insert(
            id: Value(Uuid.generate()),
            sourceCreatedAt: DateTime(2026),
            createdAt: Value(DateTime(2026)),
            threadId: Value(threadId),
            sourceUrl: Value(url),
            title: const Value('Doc'),
            priority: const Value(0),
            noteScoped: const Value(false),
          ),
        );
  }

  test('returns the canonical link whose source URL matches', () async {
    final threadId = Uuid.generate();
    await insertCanonical(threadId, 'https://x.test');
    final links = await Link.watchForThread(threadId).first;

    final match = matchingPinnedLink(links, 'https://x.test');
    expect(match, isNotNull);
    expect(match!.sourceUrl, 'https://x.test');
  });

  test('returns null when no canonical link matches the URL', () async {
    final threadId = Uuid.generate();
    await insertCanonical(threadId, 'https://other.test');
    final links = await Link.watchForThread(threadId).first;

    expect(matchingPinnedLink(links, 'https://x.test'), isNull);
  });

  test('returns null for an empty link list', () {
    expect(matchingPinnedLink(const [], 'https://x.test'), isNull);
  });
}

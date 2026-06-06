import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// The synchronous per-thread links cache lets a freshly-built ThreadWidget
/// seed its channel breadcrumb on first paint instead of popping it in a frame
/// or two later (jank when switching focuses). [Link.primeForThreads] bulk
/// warms it before the feed swaps in; [Link.cachedForThread] reads it.
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

  test('cachedForThread is null for a thread never watched or primed', () {
    expect(Link.cachedForThread(Uuid.generate()), isNull);
  });

  test('primeForThreads warms links for the given threads', () async {
    final threadWithLink = Uuid.generate();
    final linkId = Uuid.generate();
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(linkId),
            sourceCreatedAt: DateTime.now(),
            threadId: Value(threadWithLink),
            createdBy: Value(Uuid.generate()),
            channelId: const Value('chan-A'),
          ),
        );

    await Link.primeForThreads([threadWithLink]);

    final cached = Link.cachedForThread(threadWithLink);
    expect(cached, isNotNull);
    expect(cached!, hasLength(1));
    expect(cached.first.id, linkId);
  });

  test('primeForThreads caches an empty list for a thread with no links',
      () async {
    final threadNoLinks = Uuid.generate();

    await Link.primeForThreads([threadNoLinks]);

    // Distinct from "never seen" (null): a primed-but-empty answer means the
    // first paint can safely treat the row as a non-channel thread without
    // waiting for the per-row stream.
    expect(Link.cachedForThread(threadNoLinks), isNotNull);
    expect(Link.cachedForThread(threadNoLinks), isEmpty);
  });

  test('primeForThreads only queries thread ids missing from the cache',
      () async {
    final thread = Uuid.generate();
    final firstLink = Uuid.generate();
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(firstLink),
            sourceCreatedAt: DateTime.now(),
            threadId: Value(thread),
            createdBy: Value(Uuid.generate()),
          ),
        );

    await Link.primeForThreads([thread]);
    expect(Link.cachedForThread(thread), hasLength(1));

    // A second link arrives, but the thread is already cached — priming again
    // must NOT re-query it (rendered rows keep themselves live via their own
    // watchForThread subscription), so the cached snapshot is unchanged.
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(Uuid.generate()),
            sourceCreatedAt: DateTime.now(),
            threadId: Value(thread),
            createdBy: Value(Uuid.generate()),
          ),
        );
    await Link.primeForThreads([thread]);
    expect(Link.cachedForThread(thread), hasLength(1));
  });
}

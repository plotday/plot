import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/state/pending_send.dart';
import 'package:plot/store/store.dart';

final _self = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
final _threadId = ThreadId.fromString('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');

Note _publishNote({String content = 'hello'}) => Note(
  id: NoteId.fromString('dddddddd-dddd-dddd-dddd-dddddddddddd'),
  threadId: _threadId,
  authorId: _self,
  draft: false,
  content: content,
  createdAt: DateTime(2026),
  sourceCreatedAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
  });

  tearDown(() async {
    // Always leave the singleton idle for the next test.
    await PendingSend.instance.undo();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  test('start makes it pending and exposes the note', () {
    PendingSend.instance.start(note: _publishNote());
    expect(PendingSend.instance.isPending, isTrue);
    expect(PendingSend.instance.pendingNote?.content, 'hello');
    expect(PendingSend.instance.pendingThreadId, _threadId);
  });

  test('undo clears state and returns the note (no DB write)', () async {
    PendingSend.instance.start(note: _publishNote());
    final returned = await PendingSend.instance.undo();
    expect(returned?.content, 'hello');
    expect(PendingSend.instance.isPending, isFalse);
    final rows = await store.select(store.notes).get();
    expect(rows, isEmpty); // nothing was persisted during the window
  });

  test('timer fires commit after the 5s window', () {
    fakeAsync((async) {
      PendingSend.instance.start(note: _publishNote());
      expect(PendingSend.instance.isPending, isTrue);
      async.elapse(const Duration(seconds: 5));
      expect(PendingSend.instance.isPending, isFalse);
    });
  });

  test('start commits a prior pending send (one at a time)', () async {
    PendingSend.instance.start(note: _publishNote(content: 'first'));
    PendingSend.instance.start(note: _publishNote(content: 'second'));
    // The first was committed; only the second is pending.
    expect(PendingSend.instance.pendingNote?.content, 'second');
  });

  test('commit publishes the note locally (draft=false, pending set)', () async {
    PendingSend.instance.start(note: _publishNote());
    await PendingSend.instance.commit();
    final rows = await store.select(store.notes).get();
    expect(rows, hasLength(1));
    expect(rows.single.draft, isFalse);
    expect(rows.single.pending, isNotNull); // marked for sync
  });

  test('flush() with nothing pending is a no-op', () async {
    expect(PendingSend.instance.isPending, isFalse);
    await PendingSend.instance.flush(); // must not throw
    expect(PendingSend.instance.isPending, isFalse);
    final rows = await store.select(store.notes).get();
    expect(rows, isEmpty); // nothing was written
  });

  test('flush() commits a pending send', () async {
    PendingSend.instance.start(note: _publishNote());
    expect(PendingSend.instance.isPending, isTrue);
    await PendingSend.instance.flush();
    expect(PendingSend.instance.isPending, isFalse);
    final rows = await store.select(store.notes).get();
    expect(rows, hasLength(1));
    expect(rows.single.draft, isFalse);
    expect(rows.single.pending, isNotNull); // marked for sync
  });
}

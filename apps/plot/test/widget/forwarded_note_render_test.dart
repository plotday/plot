/// Tests the forward-rendering rule on [NoteWidget]: the note's own author
/// sees a live "Forwarded from {title}" link to the source thread (and never
/// the recipient-facing [ForwardUserAction] snapshot), while everyone else
/// sees the quoted snapshot the server materializes onto `actions`. See
/// `.superpowers/sdd/task-14-brief.md`.
library;

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' show FTheme;
import 'package:injector/injector.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/profile_preferences.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/note.dart';

// ---------------------------------------------------------------------------
// Fixed identities (mirror note_sending_footer_test.dart)
// ---------------------------------------------------------------------------

final _selfId = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
final _otherId = ActorId.fromString('11111111-1111-1111-1111-111111111111');
final _priorityId = Uuid.fromString('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
final _threadId = Uuid.fromString('cccccccc-cccc-cccc-cccc-cccccccccccc');
final _sourceThreadId = Uuid.fromString('dddddddd-dddd-dddd-dddd-dddddddddddd');
final _sourceNoteId = Uuid.fromString('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');

// ---------------------------------------------------------------------------
// DB insert helpers
// ---------------------------------------------------------------------------

Future<void> _insertActor(Store store, ActorId id, {required bool self}) async {
  await store.into(store.actors).insert(
        ActorsCompanion(
          id: Value(id),
          type: const Value(ActorType.contact),
          name: const Value('Me'),
          email: const Value('me@test.example'),
          self: Value(self),
          inviteable: const Value(true),
          primary: const Value(true),
        ),
      );
}

Future<void> _insertPriority(Store store, Uuid id) async {
  await store.into(store.priorities).insert(
        PrioritiesCompanion(
          id: Value(id),
          title: const Value('Test Focus'),
          createdBy: Value(_selfId.value),
          isInbox: const Value(true),
        ),
      );
}

Future<Thread> _insertThread(
  Store store, {
  required Uuid id,
  String? title,
}) async {
  await store.into(store.threads).insert(
        ThreadsCompanion(
          id: Value(id),
          priorityId: Value(_priorityId),
          contacts: Value([_selfId.value]),
          groups: const Value([]),
          draft: const Value(false),
          title: Value(title),
        ),
      );
  return Thread.getOne(id);
}

Future<void> _insertSourceNote(Store store) async {
  await store.into(store.notes).insert(
        NotesCompanion(
          id: Value(_sourceNoteId),
          threadId: Value(_sourceThreadId),
          authorId: Value(_selfId),
          content: const Value('Original body'),
          sourceCreatedAt: Value(DateTime(2026)),
        ),
      );
}

// ---------------------------------------------------------------------------
// Test widget host
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Store store;
  late LocalPreferencesBloc localPreferences;
  late Thread thread;
  late ThreadBloc bloc;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ProfilePreferences.init();

    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);

    Actor.clearCache();
    TwistInstance.clearCache();
    Channel.populateCache(const []);
    await _insertActor(store, _selfId, self: true);
    await _insertPriority(store, _priorityId);
    await Actor.get(self: true);

    Base.initForTesting(_selfId);

    localPreferences = LocalPreferencesBloc();
    await Future<void>.delayed(Duration.zero);

    thread = await _insertThread(store, id: _threadId, title: 'Destination thread');
    // The source thread/note that a forwarded note's `fwdNoteId` points at —
    // present locally only for the author in these tests, mirroring how a
    // real author's device always has their own source thread.
    await _insertThread(store, id: _sourceThreadId, title: 'Original thread');
    await _insertSourceNote(store);

    bloc = ThreadBloc(thread: thread, localPreferences: localPreferences);
  });

  tearDown(() async {
    await localPreferences.close();
    Actor.clearCache();
    TwistInstance.clearCache();
    Base.removeForTesting();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  Note authorForwardNote({List<UserAction>? actions}) => Note(
        id: NoteId.generate(),
        threadId: _threadId,
        authorId: _selfId,
        draft: false,
        content: 'fwd note body',
        fwdNoteId: _sourceNoteId,
        actions: actions,
        createdAt: DateTime(2026),
        sourceCreatedAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  Note recipientForwardNote() => Note(
        id: NoteId.generate(),
        threadId: _threadId,
        authorId: _otherId,
        draft: false,
        content: 'fwd note body',
        fwdNoteId: _sourceNoteId,
        actions: const [
          ForwardUserAction(
            sourceTitle: 'Original thread',
            sourceAuthorName: 'Alice',
            quotedContent: '> Original body',
          ),
        ],
        createdAt: DateTime(2026),
        sourceCreatedAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  Future<void> pumpNote(WidgetTester tester, Note note) async {
    await tester.pumpWidget(host(
      BlocProvider<ThreadBloc>.value(
        value: bloc,
        child: NoteWidget(note: note),
      ),
    ));
    // Let the FutureBuilder resolving the forward source (a local DB query)
    // settle. `runAsync` breaks out of the fake-async test zone so the real
    // drift/sqlite3 query genuinely completes, rather than relying on
    // `pump()`'s fake-clock advancement (which doesn't drive real I/O).
    // Avoid pumpAndSettle: some widgets in this tree keep scheduling frames
    // (e.g. tooltips) so it never reports "settled" and spins until timeout.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  group('forwarded note rendering', () {
    testWidgets('author view: shows a Forwarded-from link, hides the snapshot',
        (tester) async {
      await pumpNote(tester, authorForwardNote());

      expect(find.textContaining('Forwarded from'), findsOneWidget);
      expect(find.textContaining('Forwarded from Original thread'), findsOneWidget);
      // No blockquoted snapshot content rendered for the author.
      expect(find.textContaining('> '), findsNothing);
    });

    testWidgets(
        'author view suppresses the snapshot during loading (no flash)',
        (tester) async {
      // Post-sync note: the ForwardUserAction snapshot is already present in
      // `actions`, but the source thread hasn't been resolved yet. The author
      // must NOT flash the recipient-shaped quoted card while the async
      // `Note.get`/`Thread.getOne` resolution is still in flight.
      await tester.pumpWidget(host(
        BlocProvider<ThreadBloc>.value(
          value: bloc,
          child: NoteWidget(
            note: authorForwardNote(
              actions: const [
                ForwardUserAction(
                  sourceTitle: 'Original thread',
                  sourceAuthorName: 'Me',
                  quotedContent: '> Original body',
                ),
              ],
            ),
          ),
        ),
      ));
      // First frame: the FutureBuilder is still in ConnectionState.waiting
      // (the source resolution future hasn't been drained via runAsync). The
      // snapshot must already be suppressed — no blockquoted content.
      expect(find.textContaining('> '), findsNothing);

      // After the source resolves, still no snapshot — now with the link.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.textContaining('> '), findsNothing);
      expect(
          find.textContaining('Forwarded from Original thread'), findsOneWidget);
    });

    testWidgets('recipient view: shows the quoted snapshot, no link',
        (tester) async {
      await pumpNote(tester, recipientForwardNote());

      expect(find.textContaining('> Original body'), findsOneWidget);
      // Exactly the snapshot's own header — no separate author-side link.
      expect(find.textContaining('Forwarded from'), findsOneWidget);
      expect(find.textContaining('Forwarded from Alice — Original thread'),
          findsOneWidget);

      // The forwarded card renders full-width (it's bucketed with external
      // links in a CrossAxisAlignment.stretch Column), not as a shrink-wrapped
      // chip. On the 800px test surface, minus note gutters, a full-width card
      // is far wider than any chip would be — assert it spans most of the row.
      final cardFinder = find
          .ancestor(
            of: find.text('> Original body'),
            matching: find.byType(DecoratedBox),
          )
          .first;
      expect(tester.getSize(cardFinder).width, greaterThan(400));
    });

    testWidgets(
        'author view renders identically before and after the snapshot syncs in',
        (tester) async {
      // Pre-sync: fwdNoteId is set locally by the author's client, but the
      // server hasn't materialized the ForwardUserAction snapshot yet.
      await pumpNote(tester, authorForwardNote(actions: null));
      expect(find.textContaining('Forwarded from Original thread'), findsOneWidget);
      expect(find.textContaining('> '), findsNothing);

      // Post-sync: the snapshot has now synced onto `actions`, but the
      // author's view must be unchanged — the snapshot stays suppressed.
      await pumpNote(
        tester,
        authorForwardNote(
          actions: const [
            ForwardUserAction(
              sourceTitle: 'Original thread',
              sourceAuthorName: 'Me',
              quotedContent: '> Original body',
            ),
          ],
        ),
      );
      expect(find.textContaining('Forwarded from Original thread'), findsOneWidget);
      expect(find.textContaining('> '), findsNothing);
    });
  });
}

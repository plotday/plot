/// Tests the `sending` footer state on [NoteWidget]: when [NoteWidget.sending]
/// is true, a `SENDING ✕` ghost button replaces the author/timestamp footer
/// and tapping it calls [NoteWidget.onUndoSend].
library;

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
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
// Fixed identities (mirror thread_send_with_undo_test.dart)
// ---------------------------------------------------------------------------

final _selfId = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
final _priorityId = Uuid.fromString('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
final _threadId = Uuid.fromString('cccccccc-cccc-cccc-cccc-cccccccccccc');

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

Future<Thread> _insertThread(Store store) async {
  await store.into(store.threads).insert(
        ThreadsCompanion(
          id: Value(_threadId),
          priorityId: Value(_priorityId),
          contacts: Value([_selfId.value]),
          groups: const Value([]),
          draft: const Value(false),
        ),
      );
  return Thread.getOne(_threadId);
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

    thread = await _insertThread(store);
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

  Note makeNote({String content = 'draft text'}) => Note(
        id: NoteId.generate(),
        threadId: _threadId,
        authorId: _selfId,
        draft: false,
        content: content,
        createdAt: DateTime(2026),
        sourceCreatedAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  group('NoteWidget sending footer', () {
    testWidgets('sending=true shows SENDING button and content', (tester) async {
      var undone = false;
      final note = makeNote();

      await tester.pumpWidget(host(
        BlocProvider<ThreadBloc>.value(
          value: bloc,
          child: NoteWidget(
            note: note,
            sending: true,
            onUndoSend: () => undone = true,
          ),
        ),
      ));

      expect(find.text('SENDING'), findsOneWidget);
      expect(find.byIcon(FontAwesomeIcons.xmark), findsOneWidget);
      // NoteWidget renders content via SuperText (RichText-based), not Text widgets.
      expect(find.text('draft text', findRichText: true), findsWidgets);
      // The core requirement: the sending footer hides the commands overlay.
      expect(find.byType(NoteCommands), findsNothing);

      await tester.tap(find.text('SENDING'));
      // Drain FTappable press-state timers before the test ends.
      await tester.pumpAndSettle();
      expect(undone, isTrue);
    });

    testWidgets('sending=false does not show SENDING button', (tester) async {
      final note = makeNote();

      await tester.pumpWidget(host(
        BlocProvider<ThreadBloc>.value(
          value: bloc,
          child: NoteWidget(
            note: note,
            sending: false,
          ),
        ),
      ));

      expect(find.text('SENDING'), findsNothing);
      // NoteWidget renders content via SuperText (RichText-based), not Text widgets.
      expect(find.text('draft text', findRichText: true), findsWidgets);
      // The normal footer still renders the commands overlay.
      expect(find.byType(NoteCommands), findsOneWidget);
    });
  });
}

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/state/now.dart';
import 'package:plot/store/store.dart';

// NowBloc registers itself with WidgetsBinding in its constructor, so
// the binding must be initialized before constructing one in a unit test.
void _ensureBinding() => TestWidgetsFlutterBinding.ensureInitialized();

/// Builds a minimal [Priority] for testing — no real store required.
Priority _focus(String title, {bool isInbox = false}) => Priority.fromStore(
      PriorityRow(
        id: Uuid.generate(),
        createdBy: Uuid.generate(),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        title: title,
        path: Path(title.toLowerCase()),
        order: const Order(0),
        unread: false,
        role: 'member',
        isInbox: isInbox,
        isFyi: false,
        attentionWindowSet: false,
        seeWithinSet: false,
        earlyNotificationsEnabledSet: false,
        notifyWindowSet: false,
        sendWindowSet: false,
      ),
      draft: true,
    );

/// Seeds a [NowBloc] with a minimal [NowLoaded] state suitable for unit tests.
/// [context] is the priority the bloc starts in before the test action.
/// [everything] is the initial everything-feed flag.
NowLoaded _seedState({
  required Priority defaultPriority,
  Priority? context,
  bool everything = false,
}) =>
    NowLoaded(
      defaultPriority: defaultPriority,
      day: ScheduledDay.empty(),
      context: context,
      everything: everything,
    );

void main() {
  setUpAll(_ensureBinding);

  group('NowBloc.setContext — Everything entry (null context)', () {
    test(
        'setContext(null, everything: true) yields everything==true, '
        'context==null, no exception', () {
      final inbox = _focus('Inbox', isInbox: true);
      final work = _focus('Work');
      final bloc = NowBloc();
      addTearDown(bloc.close);

      // Start from a normal focus context.
      bloc.seedForTesting(_seedState(defaultPriority: inbox, context: work));
      expect(bloc.state, isA<NowLoaded>());
      expect((bloc.state as NowLoaded).context?.id, work.id);
      expect((bloc.state as NowLoaded).everything, isFalse);

      // Open Everything: null context, everything flag.
      // Must not throw (no Store calls are made when priority == null).
      bloc.setContext(null, everything: true);

      final loaded = bloc.state as NowLoaded;
      expect(loaded.everything, isTrue);
      expect(loaded.context, isNull);
    });

    test(
        'setContext(focus, everything: false) after Everything clears the flag '
        'and sets context to the given focus', () async {
      final inbox = _focus('Inbox', isInbox: true);
      final work = _focus('Work');

      // setContext with a non-null priority calls Store.get.updateNotificationWatermark,
      // so register a minimal in-memory store for the duration of this test.
      final store = Store.forTesting(NativeDatabase.memory());
      Injector.appInstance.registerSingleton<Store>(() => store, override: true);
      addTearDown(() async {
        Injector.appInstance.removeByKey<Store>();
        await store.close();
      });

      final bloc = NowBloc();
      addTearDown(bloc.close);

      // Start in Everything mode (null context, everything == true).
      bloc.seedForTesting(
        _seedState(defaultPriority: inbox, context: null, everything: true),
      );
      expect((bloc.state as NowLoaded).everything, isTrue);
      expect((bloc.state as NowLoaded).context, isNull);

      // Navigate to a real focus — must clear the everything flag and set context.
      bloc.setContext(work, everything: false);

      // Allow the async watermark call to complete without blocking assertions.
      await Future<void>.delayed(Duration.zero);

      final loaded = bloc.state as NowLoaded;
      expect(loaded.everything, isFalse,
          reason: 'everything flag must be cleared when navigating to a focus');
      expect(loaded.context?.id, work.id,
          reason: 'context must be set to the target focus');
    });

    test(
        'setContext(null, everything: true) is a no-op when already in Everything',
        () {
      final inbox = _focus('Inbox', isInbox: true);
      final bloc = NowBloc();
      addTearDown(bloc.close);

      // Start already in Everything mode.
      bloc.seedForTesting(
        _seedState(defaultPriority: inbox, context: null, everything: true),
      );

      // Calling again with the same state should be a no-op (early return).
      bloc.setContext(null, everything: true);

      final loaded = bloc.state as NowLoaded;
      expect(loaded.everything, isTrue);
      expect(loaded.context, isNull);
    });
  });
}

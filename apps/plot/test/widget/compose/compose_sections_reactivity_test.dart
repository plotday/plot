import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:injector/injector.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/compose_targets.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/profile_preferences.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/compose/compose_sections_view.dart';

/// Regression test for: a Slack (or any channel) connection added or archived
/// mid-session didn't update the new-thread page's Channels list until an app
/// restart.
///
/// The bloc ([ComposeTargetsBloc]) already refreshes reactively when channels
/// change (see compose_targets_test.dart's "auto-refreshes when a connection is
/// added mid-session"). The gap was in the *view*: [ComposeSectionsView] loaded
/// its sections once in initState and never re-ran them on a bloc emission, so
/// the rendered Channels list went stale.
///
/// This spy counts how many times the view asks the bloc for sections. After a
/// connection is added (and again when it's archived), the view must re-ask —
/// proving it now reacts to the bloc instead of only loading once.
class _SpyComposeTargetsBloc extends ComposeTargetsBloc {
  _SpyComposeTargetsBloc(super.prefs);

  int loadCount = 0;

  // Return empty sections so the rendered grid stays trivial (no pills → no
  // ThemeBloc / icon-font dependencies); the test only cares that the view
  // re-queries when the underlying connections change.
  @override
  Future<ComposeSections> loadSections({
    int perSection = 8,
    bool linkMode = false,
    Uuid? currentFocusId,
  }) async {
    loadCount++;
    return const ComposeSections(
      people: [],
      twists: [],
      channels: [],
      focuses: [],
    );
  }
}

void main() {
  late Store store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ProfilePreferences.init();
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
    Actor.clearCache();
    TwistInstance.clearCache();
    Channel.populateCache(const []);
  });

  tearDown(() async {
    Actor.clearCache();
    TwistInstance.clearCache();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  Widget host(ComposeTargetsBloc bloc) {
    final scheme = ColourSchemeData(
      themeColor: const ThemeColor.defaultColor(),
      brightness: Brightness.light,
    );
    return Provider<ColourSchemeData>.value(
      value: scheme,
      child: Builder(
        builder: (context) => FTheme(
          data: buildTheme(context, scheme),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 360,
              height: 640,
              child: BlocProvider<ComposeTargetsBloc>.value(
                value: bloc,
                child: ComposeSectionsView(
                  scrollController: ScrollController(),
                  searchController: TextEditingController(),
                  searchFocusNode: FocusNode(),
                  autofocusSearch: false,
                  onPickRecipient: (_) {},
                  onPickTarget: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
      'Channels list re-loads when a connection is added or archived '
      'mid-session (no app restart)', (tester) async {
    // The bloc's reactive refresh is driven by real Drift watch streams and a
    // debounce Timer, so the test must run on the real event loop
    // (`runAsync`) rather than the widget tester's fake clock.
    await tester.runAsync(() async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = _SpyComposeTargetsBloc(prefs);
      addTearDown(bloc.close);

      await tester.pumpWidget(host(bloc));
      // Let the initial view load + any constructor-driven reactive refresh
      // settle (the bloc debounces channel/twist changes by 250ms).
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();

      final loadsAfterMount = bloc.loadCount;
      expect(loadsAfterMount, greaterThan(0),
          reason: 'the view loads its sections on mount');

      // Add a channel connection AFTER the page is showing — the "didn't
      // appear until restart" case.
      await _insertConnector(store, name: 'Slack');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();

      expect(bloc.loadCount, greaterThan(loadsAfterMount),
          reason:
              'adding a connection must make the Channels list re-load, not '
              'wait for an app restart');
      final loadsAfterAdd = bloc.loadCount;

      // Archive the connection's channel — the "channels remained until
      // restart" case. Disabling drops it from Channel.watchAllEnabled,
      // re-driving the bloc's reactive refresh.
      await (store.update(store.channels)
            ..where((c) => c.channelId.equals('default')))
          .write(const ChannelsCompanion(enabled: Value(false)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();

      expect(bloc.loadCount, greaterThan(loadsAfterAdd),
          reason:
              'archiving a connection must make the Channels list re-load so '
              'the removed channels disappear without an app restart');
    });
  });
}

Future<void> _insertActor(
  Store store,
  Uuid id, {
  required String name,
  bool self = false,
}) async {
  await store.into(store.actors).insert(
        ActorsCompanion(
          id: Value(ActorId(id)),
          type: const Value(ActorType.contact),
          name: Value(name),
          email: Value('${name.replaceAll(' ', '.').toLowerCase()}@x.test'),
          self: Value(self),
          inviteable: const Value(true),
          primary: const Value(true),
        ),
      );
}

/// Inserts a channel-type connector (one enabled channel) and returns its
/// twist-instance id. Mirrors the helper in compose_targets_test.dart.
Future<Uuid> _insertConnector(Store store, {required String name}) async {
  final instanceId = Uuid.generate();
  const linkTypesJson =
      '[{"type":"thread","label":"Thread","compose":{"targets":"channels","status":"open"}}]';

  await store.into(store.twistInstances).insert(
        TwistInstancesCompanion(
          id: Value(instanceId),
          twistId: Value(BigInt.from(name.hashCode & 0x7fffffff)),
          twistEnvironment: const Value('test'),
          isSource: const Value(true),
          name: Value(name),
          config: const Value(<String, dynamic>{}),
          linkTypes: const Value(linkTypesJson),
        ),
      );
  await TwistInstance.get();

  await store.into(store.channels).insert(
        ChannelsCompanion(
          id: Value(BigInt.from('default'.hashCode & 0x7fffffff)),
          twistInstanceId: Value(instanceId),
          channelId: const Value('default'),
          title: Value('$name channel'),
          enabled: const Value(true),
          linkTypes: const Value(linkTypesJson),
        ),
      );
  Channel.populateCache(await Channel.getAllEnabled());

  return instanceId;
}

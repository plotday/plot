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
import 'package:plot/state/theme.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/profile_preferences.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/compose/compose_pill.dart';
import 'package:plot/widget/compose/connection_picker_view.dart';

/// When no connection can reach the chosen recipient — they are not on Plot,
/// have no email, and no connected app has an account for them — the connection
/// picker shows an explanatory empty state rather than a blank grid (#3).
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

  Widget host(ComposeTargetsBloc bloc, ComposePeopleEntry recipient) {
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
              child: MultiBlocProvider(
                providers: [
                  BlocProvider<ComposeTargetsBloc>.value(value: bloc),
                  BlocProvider<ThemeBloc>(create: (_) => ThemeBloc()),
                ],
                child: ConnectionPickerView(
                  recipient: recipient,
                  scrollController: ScrollController(),
                  searchController: TextEditingController(),
                  searchFocusNode: FocusNode(),
                  onPickConnection: (_) {},
                  onBack: () {},
                  autofocusSearch: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
      'shows the no-reachable-connections empty state for an unreachable contact',
      (tester) async {
    await tester.runAsync(() async {
      final self = Uuid.generate();
      final ghost = Uuid.generate();
      await store.into(store.actors).insert(
            ActorsCompanion(
              id: Value(ActorId(self)),
              type: const Value(ActorType.user),
              name: const Value('Me'),
              email: const Value('me@x.test'),
              self: const Value(true),
              inviteable: const Value(true),
              primary: const Value(true),
            ),
          );
      await store.into(store.actors).insert(
            ActorsCompanion(
              id: Value(ActorId(ghost)),
              type: const Value(ActorType.contact),
              name: const Value('No Reach'),
              email: const Value<String?>(null),
              self: const Value(false),
              inviteable: const Value(true),
              primary: const Value(true),
            ),
          );
      await Actor.get(self: true);
      final actor = await Actor.getOne(ActorId.fromUuid(ghost));

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final recipient = ComposePeopleEntry(
        contacts: [ghost],
        groups: const [],
        inviteEmails: const [],
        display: ContactPillData(actor),
      );

      await tester.pumpWidget(host(bloc, recipient));
      // connectionsForRoster runs in initState against real Drift queries.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.text('No way to reach this contact yet'), findsOneWidget);
    });
  });
}

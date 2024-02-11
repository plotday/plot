import 'package:flutter/material.dart';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'env.dart';

import 'account/sign_in_page.dart';
import 'now/page.dart';
import 'priority/page.dart';
import 'schedule/page.dart';
import 'account/page.dart';

import 'priority/bloc.dart';
import 'priority/activity.dart';
import 'now/bloc.dart';
import 'now/time_block.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: Env.supabaseUrl,
    anonKey: Env.supabaseAnonKey,
  );

  await SentryFlutter.init(
    (options) {
      options.dsn = Env.sentryDsn;
    },
    appRunner: () => runApp(const App()),
  );
}

final supabase = Supabase.instance.client;

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return AdaptiveTheme(
      light: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0x002BDD66),
          brightness: Brightness.light,
        ),
      ),
      dark: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0x002BDD66),
          brightness: Brightness.dark,
        ),
      ),
      debugShowFloatingThemeButton: true,
      initial: AdaptiveThemeMode.system,
      builder: (theme, darkTheme) => MaterialApp(
        title: 'Plot',
        theme: theme,
        darkTheme: darkTheme,
        home: SignInPage(
          builder: (context) {
            return FutureBuilder(
              future: Future.wait([Activity.load(), TimeBlock.load()]),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                return MultiBlocProvider(
                  providers: [
                    BlocProvider(create: (_) => PrioritiesBloc()),
                    BlocProvider(create: (_) => NowBloc()),
                  ],
                  child: const Layout(title: 'Plot'),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class Layout extends StatefulWidget {
  const Layout({super.key, required this.title});

  final String title;

  @override
  State<Layout> createState() => LayoutState();
}

class LayoutState extends State<Layout> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this, initialIndex: 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        bottomNavigationBar: NavigationBar(
          onDestinationSelected: (int index) {
            setState(() {
              _tabController.animateTo(index);
            });
          },
          selectedIndex: _tabController.index,
          destinations: const <Widget>[
            NavigationDestination(
              icon: Icon(Icons.crisis_alert),
              label: 'Priorities',
            ),
            NavigationDestination(
              icon: Icon(Icons.schedule),
              label: 'Now',
            ),
            NavigationDestination(
              icon: Icon(Icons.calendar_today),
              label: 'Schedule',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
        body: TabBarView(
          controller: _tabController,
          children: const [
            PrioritiesPage(),
            NowPage(),
            SchedulePage(),
            AccountPage(),
          ],
        ));
  }
}

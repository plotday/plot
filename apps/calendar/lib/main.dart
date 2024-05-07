import 'package:flutter/material.dart';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';

import 'env.dart';
import 'router.dart';

Future<void> main() async {
  GoRouter.optionURLReflectsImperativeAPIs = true;
  usePathUrlStrategy();
  await SentryFlutter.init(
    (options) {
      options.dsn = Env.sentryDsn;
    },
    appRunner: () async {
      await Supabase.initialize(
        url: Env.supabaseUrl,
        anonKey: Env.supabaseAnonKey,
      );
      return runApp(const App());
    },
  );
}

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
      builder: (theme, darkTheme) => MaterialApp.router(
        title: 'Plot',
        theme: theme,
        darkTheme: darkTheme,
        routerConfig: router,
      ),
    );
  }
}

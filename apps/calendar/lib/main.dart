import 'package:flutter/material.dart';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import 'env.dart';
import 'router.dart';
import 'account/sign_in_page.dart';
import 'now/bloc.dart';
import 'now/time_block.dart';
import 'priority/activity.dart';
import 'priority/bloc.dart';
import 'priority/context.dart';

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
      builder: (theme, darkTheme) => SignInPage(
        builder: (context) {
          return FutureBuilder(
            future: Future.wait(
                [Context.load(), Activity.load(), TimeBlock.load()]),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return MultiBlocProvider(
                providers: [
                  BlocProvider(create: (_) => PrioritiesBloc()),
                  BlocProvider(create: (_) => NowBloc()),
                ],
                child: MaterialApp.router(
                  title: 'Plot',
                  theme: theme,
                  darkTheme: darkTheme,
                  routerConfig: router,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

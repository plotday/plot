import 'package:plot/state/root_provider.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/settings.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

import 'widget/window.dart';
import 'widget/widget.dart';
import 'command/command.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  AppState createState() => AppState();
}

class AppState extends State<App> {
  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => ThemeBloc()),
        BlocProvider(create: (_) => LocalPreferencesBloc()),
        BlocProvider(create: (_) => SettingsBloc()),
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ColourScheme(
          child: Builder(
            builder: (context) => Window(
              child: CommandProvider(
                child: FTheme(
                  data: buildTheme(context.colour),
                  child: RootProvider(
                    builder: (routerConfig) => PlatformBuilder(
                      builder: (context) => AdaptiveTheme(
                        light: material.ThemeData(
                          colorScheme: material.ColorScheme.fromSeed(
                            seedColor: const Color(0x002BDD66),
                            brightness: material.Brightness.light,
                          ),
                        ),
                        dark: material.ThemeData(
                          colorScheme: material.ColorScheme.fromSeed(
                            seedColor: const Color(0x002BDD66),
                            brightness: material.Brightness.dark,
                          ),
                        ),
                        debugShowFloatingThemeButton: true,
                        initial: AdaptiveThemeMode.system,
                        builder: (theme, darkTheme) =>
                            material.MaterialApp.router(
                              title: 'Plot',
                              localizationsDelegates:
                                  FLocalizations.localizationsDelegates,
                              supportedLocales: FLocalizations.supportedLocales,
                              theme: theme,
                              darkTheme: darkTheme,
                              routerConfig: routerConfig,
                            ),
                      ),
                      macOSBuilder: (context) => macos.MacosApp.router(
                        title: 'Plot',
                        localizationsDelegates:
                            FLocalizations.localizationsDelegates,
                        supportedLocales: FLocalizations.supportedLocales,
                        theme:
                            (context.colour.brightness == Brightness.light
                                    ? macos.MacosThemeData.light()
                                    : macos.MacosThemeData.dark())
                                .copyWith(primaryColor: context.colour.accent),
                        debugShowCheckedModeBanner: false,
                        routerConfig: routerConfig,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ErrorApp extends StatelessWidget {
  final Object error;

  const ErrorApp({required this.error, super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => ThemeBloc()),
        BlocProvider(create: (_) => LocalPreferencesBloc()),
        BlocProvider(create: (_) => SettingsBloc()),
      ],
      child: PlatformBuilder(
        builder: (context) => material.MaterialApp(
          home: ColourScheme(
            child: material.Scaffold(
              body: Directionality(
                textDirection: TextDirection.ltr,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 8,
                    children: [
                      const Text('Failed to start Plot.'),
                      Text('Error: $error'),
                      Button(SignOut(), expand: false),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

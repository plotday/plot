import 'package:plot/state/root_provider.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/settings.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

import 'widget/window.dart';
import 'widget/widget.dart';
import 'command/command.dart';

class PlotScrollBehavior extends material.MaterialScrollBehavior {
  const PlotScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // Only Android uses the Material stretch/glow overscroll indicator.
    // iOS/macOS use bounce physics (inherent feedback), Windows/web have none.
    if (material.Theme.of(context).platform == material.TargetPlatform.android) {
      return super.buildOverscrollIndicator(context, child, details);
    }
    return child;
  }
}

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
                  data: buildTheme(context, context.colour),
                  child: FToaster(
                    child: RootProvider(
                      builder: (routerConfig) => PlatformBuilder(
                        builder: (context) => material.MaterialApp.router(
                          title: 'Plot',
                          scrollBehavior: const PlotScrollBehavior(),
                          localizationsDelegates:
                              FLocalizations.localizationsDelegates,
                          supportedLocales:
                              FLocalizations.supportedLocales,
                          theme: material.ThemeData(
                            colorScheme: material.ColorScheme.fromSeed(
                              seedColor: const Color(0x002BDD66),
                              brightness:
                                  context.colour.brightness == Brightness.light
                                      ? material.Brightness.light
                                      : material.Brightness.dark,
                            ),
                          ),
                          routerConfig: routerConfig,
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
                                  .copyWith(
                                    primaryColor: context.colour.accent,
                                  ),
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

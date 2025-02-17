import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:plot/state/root_provider.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;

import 'router.dart';
import 'widget/window.dart';
import 'widget/widget.dart';
import 'page/loading.dart';
import 'command/settings.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  AppState createState() => AppState();
}

class AppState extends State<App> with WidgetsBindingObserver {
  late Future<PanelLayout> layout;

  @override
  void initState() {
    super.initState();

    final layoutCompleter = Completer<PanelLayout>();
    layout = layoutCompleter.future;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Window.init();
      Layout.init(context).then((layout) {
        if (!mounted) {
          throw "Context is not mounted";
        }
        return layoutCompleter.complete(layout);
      }).catchError((dynamic error) {
        if (error is Object) {
          layoutCompleter.completeError(error);
        } else {
          layoutCompleter.completeError("Unknown error");
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: FutureBuilder(
        future: layout,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            print(snapshot.error);
            print(snapshot.stackTrace);
            return const Center(
                child: Text(
              "Something went wrong",
            ));
          }
          if (!snapshot.hasData) {
            return const LoadingPage();
          }
          return RootProvider(
            child: RouterBuilder(
              layout: snapshot.data!,
              builder: (context, router) => PlatformBuilder(
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
                  builder: (theme, darkTheme) => snapshot.data == null
                      ? material.MaterialApp(
                          theme: theme,
                          darkTheme: darkTheme,
                        )
                      : material.MaterialApp.router(
                          title: 'Plot',
                          theme: theme,
                          darkTheme: darkTheme,
                          routerConfig: router,
                        ),
                ),
                macOSBuilder: (context) => snapshot.data == null
                    ? const macos.MacosApp()
                    : macos.MacosApp.router(
                        title: 'Plot',
                        debugShowCheckedModeBanner: false,
                        routerConfig: router,
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class ErrorApp extends StatelessWidget {
  final Object error;

  const ErrorApp({required this.error, super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      builder: (context) => material.MaterialApp(
        home: material.Scaffold(
          body: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Failed to start Plot.'),
                  Text('Error: $error'),
                  Button(
                    onTap: () {
                      SignOut().run(context);
                    },
                    child: const Text('Sign Out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

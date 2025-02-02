import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:plot/state/root_provider.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;

import 'state/user.dart';
import 'router.dart';
import 'widget/layout.dart';
import 'widget/spinner.dart';
import 'command/global.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  AppState createState() => AppState();
}

class AppState extends State<App> with WidgetsBindingObserver {
  late Future<GoRouter> router;

  @override
  void initState() {
    super.initState();

    final routeCompleter = Completer<GoRouter>();
    router = routeCompleter.future;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Layout.init(context)
          .then((layout) => routeCompleter.complete(getRouter(layout)))
          .catchError((dynamic error) {
        if (error is Object) {
          routeCompleter.completeError(error);
        } else {
          routeCompleter.completeError("Unknown error");
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: FutureBuilder(
        future: router,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            print(snapshot.error);
            print(snapshot.stackTrace);
            return const Center(
                child: Text(
              "Something went wrong",
              textDirection: TextDirection.ltr,
            ));
          }
          if (!snapshot.hasData) {
            return const Center(child: Spinner());
          }
          return RootProvider(
            child: BlocListener<UserBloc, UserState>(
              listener: (context, state) {
                snapshot.data?.refresh();
              },
              child: GlobalShortcuts(
                child: PlatformBuilder(
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
                            routerConfig: snapshot.data,
                          ),
                  ),
                  macOSBuilder: (context) => snapshot.data == null
                      ? const macos.MacosApp()
                      : macos.MacosApp.router(
                          title: 'Plot',
                          debugShowCheckedModeBanner: false,
                          routerConfig: snapshot.data,
                        ),
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

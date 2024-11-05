import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;

import 'widget/layout.dart';
import 'package:plot/state/user.dart';
import 'package:plot/router.dart';
import 'package:plot/widget/spinner.dart';

class App extends StatefulWidget {
  static Future<void> init() async {
    if (Platform.instance.isMacOS) {
      await const macos.MacosWindowUtilsConfig().apply();
    }
  }

  const App({super.key});

  @override
  AppState createState() => AppState();
}

class AppState extends State<App> with WidgetsBindingObserver {
  late Future<GoRouter> router;

  @override
  void initState() {
    super.initState();
    router = Layout.getLayout(context).then((layout) => getRouter(layout));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: router,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          print(snapshot.error);
          print(snapshot.stackTrace);
          return const Center(child: Text("Something went wrong"));
        }
        if (!snapshot.hasData) {
          return const Center(child: Spinner());
        }
        return BlocProvider<UserBloc>(
          create: (_) => UserBloc(),
          child: BlocListener<UserBloc, UserState>(
            listener: (context, state) {
              snapshot.data?.refresh();
            },
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
                builder: (theme, darkTheme) => material.MaterialApp.router(
                  title: 'Plot',
                  theme: theme,
                  darkTheme: darkTheme,
                  routerConfig: snapshot.data,
                ),
              ),
              macOSBuilder: (context) => macos.MacosApp.router(
                title: 'Plot',
                debugShowCheckedModeBanner: false,
                routerConfig: snapshot.data,
              ),
            ),
          ),
        );
      },
    );
  }
}

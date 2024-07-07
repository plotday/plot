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
  late ValueNotifier<RoutingConfig> routingConfig;
  late GoRouter router;
  bool _initialized = false;
  late PanelLayout _lastLayout;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  PanelLayout _getLayout() {
    return Layout.getLayout(context);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _lastLayout = _getLayout();
    routingConfig = ValueNotifier<RoutingConfig>(getRoutingConfig(_lastLayout));
    router = GoRouter.routingConfig(
      routingConfig: routingConfig,
    );
    _initialized = true;
  }

  @override
  void didChangeMetrics() {
    final layout = _getLayout();
    if (layout == _lastLayout) return;
    _lastLayout = layout;
    routingConfig.value = getRoutingConfig(_lastLayout);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    routingConfig.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<UserBloc>(
      create: (_) => UserBloc(),
      child: BlocListener<UserBloc, UserState>(
        listener: (context, state) {
          router.refresh();
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
              routerConfig: router,
            ),
          ),
          macOSBuilder: (context) => macos.MacosApp.router(
            title: 'Plot',
            debugShowCheckedModeBanner: false,
            routerConfig: router,
          ),
        ),
      ),
    );
  }
}

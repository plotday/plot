import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import 'style.dart';
import 'app_mac.dart';
import 'app_material.dart';
import 'layout.dart';
import 'package:plot/state/user.dart';
import 'package:plot/router.dart';

class App extends StatefulWidget {
  static Future<void> init() async {
    switch (style) {
      case Style.mac:
        await MacApp.init();
      default:
        break;
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
  late RouteChangeObserver _routeStream;

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
    _routeStream = RouteChangeObserver();
    _lastLayout = _getLayout();
    routingConfig = ValueNotifier<RoutingConfig>(getRoutingConfig(_lastLayout));
    router = GoRouter.routingConfig(
      routingConfig: routingConfig,
      observers: [_routeStream],
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
      child: RouteContext(
        routeChangeObserver: _routeStream,
        child: BlocListener<UserBloc, UserState>(
          listener: (context, state) {
            router.refresh();
          },
          child: switch (style) {
            Style.mac => MacApp(router),
            Style.ios => const Text("TODO"),
            Style.material => MaterialApp(router),
            Style.windows => const Text("TODO"),
          },
        ),
      ),
    );
  }
}

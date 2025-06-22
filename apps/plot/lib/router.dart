import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:logging/logging.dart';

import 'store/store.dart';
import 'state/now.dart';
import 'page/page.dart';
import 'widget/global_menu.dart';
import 'widget/dialog.dart';
import 'command/global.dart';

export 'package:auto_route/auto_route.dart';

part 'router.gr.dart';

final Logger _logger = Logger('plot.route');

@RoutePage(name: 'AppShellRoute')
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return DialogProvider(
      child: GlobalMenu(child: GlobalShortcuts(child: AutoRouter())),
    );
  }
}

@AutoRouterConfig(generateForDir: ['lib', 'lib/page'])
class AppRouter extends RootStackRouter {
  @override
  RouteType get defaultRouteType => PlatformResolver.current(
    iOSResolver: () => RouteType.cupertino(),
    androidResolver: () => RouteType.material(),
    defaultResolver: () => RouteType.custom(
      duration: const Duration(milliseconds: 100),
      reverseDuration: const Duration(milliseconds: 10),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    ),
  );

  @override
  List<AutoRoute> get routes => <AutoRoute>[
    AutoRoute(
      page: AppShellRoute.page,
      path: '/',
      children: [
        AutoRoute(
          page: EmptyShellRoute("Now"),
          path: '',
          guards: [
            AutoRouteGuardCallback((resolver, router) async {
              final priorityId = resolver.context
                  .read<NowBloc>()
                  .loadedState
                  .priority
                  .id;
              resolver.redirectUntil(PriorityRoute(priorityId: priorityId));
            }),
          ],
        ),
        AutoRoute(page: SignInRoute.page, path: 'login'),
        AutoRoute(page: PrioritiesRoute.page, path: 'priorities'),
        AutoRoute(
          page: PriorityRoute.page,
          path: 'p/:priorityId',
          children: [AutoRoute(page: PriorityMainRoute.page, path: '')],
        ),
        AutoRoute(
          page: ActivityRoute.page,
          path: 'a/:activityId',
          children: [AutoRoute(page: ActivityMainRoute.page, path: '')],
        ),
      ],
    ),
  ];

  @override
  RouterConfig<UrlState> config({
    DeepLinkTransformer? deepLinkTransformer,
    DeepLinkBuilder? deepLinkBuilder,
    String? navRestorationScopeId,
    WidgetBuilder? placeholder,
    NavigatorObserversBuilder navigatorObservers =
        AutoRouterDelegate.defaultNavigatorObserversBuilder,
    bool includePrefixMatches = !kIsWeb,
    bool Function(String? location)? neglectWhen,
    bool rebuildStackOnDeepLink = false,
    Listenable? reevaluateListenable,
    Clip clipBehavior = Clip.hardEdge,
  }) {
    return super.config(
      deepLinkTransformer: deepLinkTransformer,
      deepLinkBuilder: deepLinkBuilder,
      navRestorationScopeId: navRestorationScopeId,
      placeholder: placeholder,
      navigatorObservers: () => [RouteLogger(), ...navigatorObservers()],
      includePrefixMatches: includePrefixMatches,
      neglectWhen: neglectWhen,
      rebuildStackOnDeepLink: rebuildStackOnDeepLink,
      reevaluateListenable: reevaluateListenable,
      clipBehavior: clipBehavior,
    );
  }
}

extension FocusedRouterExtension on BuildContext {
  StackRouter get focusedRouter {
    var focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext?.router ?? router;
  }
}

class RouteLogger extends AutoRouterObserver {
  void _log(Route<dynamic> route) {
    if (route.settings.name != null) {
      _logger.info(
        'Navigated to ${route.settings.name}${route.settings.arguments == null ? '' : ' (${route.settings.arguments})'}',
      );
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _log(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _log(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    _log(newRoute);
  }
}

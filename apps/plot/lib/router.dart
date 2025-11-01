import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:logging/logging.dart';

import 'store/store.dart';
import 'state/now.dart';
import 'state/user.dart';
import 'state/layout.dart';
import 'page/page.dart';
import 'widget/app_shell.dart';
import 'widget/priorities_shell.dart';

export 'package:auto_route/auto_route.dart';

part 'router.gr.dart';

final Logger _logger = Logger('plot.route');

@AutoRouterConfig(generateForDir: ['lib', 'lib/page'])
class AppRouter extends RootStackRouter {
  AppRouter();
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
        AutoRoute(page: SignInRoute.page, path: 'login'),
        AutoRoute(
          page: InvitationRoute.page,
          path: 'invitation',
          guards: [AuthGuard()],
        ),
        AutoRoute(
          page: EmptyShellRoute("Now"),
          path: '',
          guards: [
            AuthGuard(),
            AutoRouteGuardCallback((resolver, router) async {
              if (resolver.context.read<NowBloc>().loading) {
                return;
              }
              final priorityId = resolver.context
                  .read<NowBloc>()
                  .loadedState
                  .priority
                  .id;
              resolver.redirectUntil(
                PriorityRoute(priorityIdString: priorityId.toShortString()),
              );
            }),
          ],
        ),
        AutoRoute(
          page: PrioritiesShellRoute.page,
          guards: [AuthGuard()],
          path: '',
          children: [
            AutoRoute(
              page: PrioritiesRoute.page,
              path: '',
              guards: [
                // If we're in a multi-panel layout, redirect to the current priority
                AutoRouteGuardCallback((resolver, router) async {
                  final layout = resolver.context.read<LayoutBloc>().state;
                  if (layout.multiPanel) {
                    final priorityId = resolver.context
                        .read<NowBloc>()
                        .loadedState
                        .priority
                        .id;
                    resolver.redirectUntil(
                      PriorityRoute(
                        priorityIdString: priorityId.toShortString(),
                      ),
                    );
                  }
                }),
              ],
            ),
            AutoRoute(
              page: PriorityRoute.page,
              path: ':priorityId',
              children: [
                AutoRoute(
                  page: PriorityMainRoute.page,
                  path: '',
                  guards: [
                    // In multi-panel mode, redirect to NewActivityRoute
                    AutoRouteGuardCallback((resolver, router) async {
                      final layout = resolver.context.read<LayoutBloc>().state;
                      if (layout.multiPanel) {
                        resolver.redirectUntil(const NewActivityRoute());
                      } else {
                        resolver.next();
                      }
                    }),
                  ],
                ),
                AutoRoute(page: NewActivityRoute.page, path: 'new'),
                AutoRoute(
                  page: ActivityRoute.page,
                  path: ':activityId',
                  children: [AutoRoute(page: ActivityMainRoute.page, path: '')],
                ),
              ],
            ),
          ],
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
      navigatorObservers: () => [
        RouteLogger(),
        AutoRouteObserver(),
        ...navigatorObservers(),
      ],
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

class AuthGuard extends AutoRouteGuard {
  AuthGuard();

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) {
    final userState = resolver.context.read<UserBloc>().state;

    if (userState is UserReady) {
      // User is authenticated and active, proceed with navigation
      resolver.next();
    } else if (userState is UserWaitlisted &&
        resolver.route.name != 'InvitationRoute') {
      resolver.redirectUntil(InvitationRoute());
    } else if (userState is UserSignedOut && resolver.route is! SignInRoute) {
      // User is not authenticated, redirect to sign in with return path
      final returnPath = resolver.route.path;
      router.navigate(
        SignInRoute(
          returnTo: returnPath is! SignInRoute ? returnPath : null,
          signOut: true,
        ),
      );
    } else {
      // User state is loading, wait for authentication to complete
      // This will be handled by the UserBloc listener
      resolver.next();
    }
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

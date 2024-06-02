import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'state/user.dart';
import 'state/root_provider.dart';
import 'page/sign_in.dart';
import 'page/schedule.dart';
import 'page/priority.dart';
import 'page/event.dart';
import 'platform/layout.dart';

part 'router.g.dart';

class NavigationContext extends InheritedWidget {
  static StatefulNavigationShell of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<NavigationContext>()!
        .navigationShell;
  }

  const NavigationContext({
    required this.navigationShell,
    required super.child,
    super.key,
  });
  final StatefulNavigationShell navigationShell;

  @override
  bool updateShouldNotify(NavigationContext oldWidget) {
    return navigationShell != oldWidget.navigationShell;
  }
}

class RouteChange {
  final Route<dynamic>? currentRoute;
  final Route<dynamic>? previousRoute;
  final String changeType;

  RouteChange({
    required this.currentRoute,
    required this.previousRoute,
    required this.changeType,
  });
}

class RouteChangeObserver extends NavigatorObserver {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _emitRouteChange(previousRoute, route, 'pop');
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _emitRouteChange(route, previousRoute, 'push');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _emitRouteChange(previousRoute, route, 'remove');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _emitRouteChange(newRoute, oldRoute, 'replace');
  }

  @override
  void didStartUserGesture(
      Route<dynamic> route, Route<dynamic>? previousRoute) {}
  @override
  void didStopUserGesture() {}

  final _streamController = StreamController<RouteChange>.broadcast();

  Stream<RouteChange> get stream => _streamController.stream;

  void _emitRouteChange(
    Route<dynamic>? currentRoute,
    Route<dynamic>? previousRoute,
    String changeType,
  ) {
    _streamController.add(
      RouteChange(
        currentRoute: currentRoute,
        previousRoute: previousRoute,
        changeType: changeType,
      ),
    );
  }
}

class RouteContext extends InheritedWidget {
  static RouteContext of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<RouteContext>()!;
  }

  const RouteContext({
    required this.routeChangeObserver,
    required super.child,
    super.key,
  });

  final RouteChangeObserver routeChangeObserver;

  @override
  bool updateShouldNotify(RouteContext oldWidget) {
    return false;
  }
}

@TypedGoRoute<HomeRoute>(path: '/')
class HomeRoute extends GoRouteData {
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      const NoTransitionPage(
        child: TripleLayout(SchedulePage(), PriorityPage(), EventPageLoader()),
      );
}

@TypedGoRoute<LoginRoute>(path: '/login')
class LoginRoute extends GoRouteData {
  const LoginRoute();

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      const NoTransitionPage(
        child: SignInPage(),
      );
}

@TypedGoRoute<EventRoute>(path: '/e/:eventId')
class EventRoute extends GoRouteData {
  EventRoute({required this.eventId});

  final int eventId;

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    return NoTransitionPage(
      child: EventPageLoader(eventId: eventId),
    );
  }
}

final _singleRoutes = [
  StatefulShellRoute.indexedStack(
      builder: (
        BuildContext context,
        GoRouterState state,
        StatefulNavigationShell navigationShell,
      ) {
        return NavigationContext(
          navigationShell: navigationShell,
          child: navigationShell,
        );
      },
      branches: <StatefulShellBranch>[
        StatefulShellBranch(
          // navigatorKey: _sectionANavigatorKey,
          routes: <RouteBase>[
            GoRoute(
              path: '/priorities',
              pageBuilder: (context, state) {
                return NoTransitionPage(
                  child: SingleLayout(
                    NavigationContext.of(context),
                    const PriorityPage(),
                  ),
                );
              },
            ),
          ],
        ),
        StatefulShellBranch(
          // navigatorKey: _sectionANavigatorKey,
          routes: <RouteBase>[
            GoRoute(
              path: '/',
              pageBuilder: (context, state) {
                return NoTransitionPage(
                  child: SingleLayout(
                    NavigationContext.of(context),
                    const SchedulePage(),
                  ),
                );
              },
            ),
          ],
        )
      ])
];

final _doubleRoutes = [
  StatefulShellRoute.indexedStack(
      builder: (
        BuildContext context,
        GoRouterState state,
        StatefulNavigationShell navigationShell,
      ) {
        return NavigationContext(
          navigationShell: navigationShell,
          child: navigationShell,
        );
      },
      branches: <StatefulShellBranch>[
        StatefulShellBranch(
          // navigatorKey: _sectionANavigatorKey,
          routes: <RouteBase>[
            GoRoute(
              path: '/priorities',
              pageBuilder: (context, state) {
                return NoTransitionPage(
                  child: DoubleLayout(
                    NavigationContext.of(context),
                    const PriorityPage(),
                    const Text("ContextPage"),
                  ),
                );
              },
            ),
          ],
        ),
        StatefulShellBranch(
          // navigatorKey: _sectionANavigatorKey,
          routes: <RouteBase>[
            GoRoute(
              path: '/',
              pageBuilder: (context, state) {
                return NoTransitionPage(
                  child: DoubleLayout(
                    NavigationContext.of(context),
                    const SchedulePage(),
                    const EventPageLoader(),
                  ),
                );
              },
            ),
          ],
        )
      ])
];

final _tripleRoutes = [
  GoRoute(
    path: '/',
    pageBuilder: (context, state) {
      return const NoTransitionPage(
        child: TripleLayout(SchedulePage(), PriorityPage(), EventPageLoader()),
      );
    },
  ),
  GoRoute(
    name: 'event',
    path: '/e/:id',
    pageBuilder: (context, state) {
      return const NoTransitionPage(
        child: TripleLayout(SchedulePage(), PriorityPage(), EventPageLoader()),
      );
    },
  ),
];

RoutingConfig getRoutingConfig(PanelLayout layout) {
  return RoutingConfig(
    routes: [
      ShellRoute(
        builder: (context, state, child) {
          return RootProvider(
            key: const Key('RootProvider'),
            child: child,
          );
        },
        routes: switch (layout) {
          PanelLayout.single => _singleRoutes,
          PanelLayout.double => _doubleRoutes,
          PanelLayout.triple => _tripleRoutes,
        },
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) {
          return const NoTransitionPage(
            child: SignInPage(),
          );
        },
      ),
    ],
    redirect: (BuildContext context, GoRouterState state) async {
      // Using `of` method creates a dependency of StreamAuthScope. It will
      // cause go_router to reparse current route if StreamAuth has new sign-in
      // information.
      final bool loggedIn = context.read<UserBloc>().state is UserSignedIn;
      final bool loggingIn = state.matchedLocation == '/login';
      if (!loggedIn) {
        return '/login';
      }

      // if the user is logged in but still on the login page, send them to
      // the home page
      if (loggingIn) {
        return '/';
      }

      // no need to redirect at all
      return null;
    },
  );
}

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

@TypedGoRoute<LoginRoute>(path: '/login')
class LoginRoute extends GoRouteData {
  const LoginRoute();

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      const NoTransitionPage(
        child: SignInPage(),
      );
}

abstract class AdaptiveRoute extends GoRouteData {
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      switch (Layout.getLayout(context)) {
        PanelLayout.single => buildSinglePage(context, state),
        PanelLayout.double => buildDoublePage(context, state),
        PanelLayout.triple => buildTriplePage(context, state),
      };

  Page<void> buildSinglePage(BuildContext context, GoRouterState state);
  Page<void> buildDoublePage(BuildContext context, GoRouterState state);
  Page<void> buildTriplePage(BuildContext context, GoRouterState state);
}

@TypedGoRoute<HomeRoute>(path: '/', name: 'home:triple')
class HomeRoute extends AdaptiveRoute {
  @override
  Page<void> buildTriplePage(BuildContext context, GoRouterState state) =>
      const NoTransitionPage(
        child: TripleLayout(SchedulePage(), PriorityPage(), EventPageLoader()),
      );

  @override
  Page<void> buildDoublePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: DoubleLayout(
          NavigationContext.of(context),
          const SchedulePage(),
          const EventPageLoader(),
        ),
      );

  @override
  Page<void> buildSinglePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: SingleLayout(
          NavigationContext.of(context),
          const SchedulePage(),
        ),
      );
}

@TypedGoRoute<EventRoute>(path: '/e/:eventId', name: 'event:triple')
class EventRoute extends AdaptiveRoute {
  EventRoute({required this.eventId});

  final int eventId;

  @override
  Page<void> buildSinglePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
          child: SingleLayout(
        NavigationContext.of(context),
        EventPageLoader(eventId: eventId),
      ));

  @override
  Page<void> buildDoublePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
          child: DoubleLayout(
        NavigationContext.of(context),
        const SchedulePage(),
        EventPageLoader(eventId: eventId),
      ));

  @override
  Page<void> buildTriplePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
          child: TripleLayout(
        const SchedulePage(),
        const PriorityPage(),
        EventPageLoader(eventId: eventId),
      ));
}

class PrioritiesRoute extends AdaptiveRoute {
  @override
  Page<void> buildTriplePage(BuildContext context, GoRouterState state) =>
      const NoTransitionPage(
        child: TripleLayout(
          SchedulePage(),
          PriorityPage(),
          PriorityPage(),
        ),
      );

  @override
  Page<void> buildDoublePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: DoubleLayout(
          NavigationContext.of(context),
          const PriorityPage(),
          const SchedulePage(),
        ),
      );

  @override
  Page<void> buildSinglePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: SingleLayout(
          NavigationContext.of(context),
          const PriorityPage(),
        ),
      );
}

class PrioritiesBranch extends StatefulShellBranchData {
  const PrioritiesBranch();
}

class ScheduleBranch extends StatefulShellBranchData {
  const ScheduleBranch();
}

@TypedStatefulShellRoute<_SingleRoutes>(
  branches: [
    TypedStatefulShellBranch<ScheduleBranch>(
      routes: <TypedGoRoute<GoRouteData>>[
        TypedGoRoute<HomeRoute>(
          path: '/',
          name: 'home:single',
          routes: [
            TypedGoRoute<EventRoute>(
              path: 'e/:eventId',
              name: 'event:single',
            ),
          ],
        ),
      ],
    ),
    TypedStatefulShellBranch<PrioritiesBranch>(
      routes: <TypedGoRoute<GoRouteData>>[
        TypedGoRoute<PrioritiesRoute>(
          path: '/priorities',
          name: 'priorities:single',
        ),
      ],
    ),
  ],
)
class _SingleRoutes extends StatefulShellRouteData {
  const _SingleRoutes();

  @override
  Widget builder(
    BuildContext context,
    GoRouterState state,
    StatefulNavigationShell navigationShell,
  ) {
    return NavigationContext(
      navigationShell: navigationShell,
      child: navigationShell,
    );
  }
}

List<RouteBase> _filterRoutes(PanelLayout layout) => $appRoutes
    .where((route) =>
        route is! GoRoute ||
        route.name?.contains(':') != true ||
        route.name?.endsWith(":${layout.name}") == true)
    .toList();

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
        routes: _filterRoutes(layout),
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

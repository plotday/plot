import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'widget/widget.dart';
import 'router.dart';

part 'router_tabbed.g.dart';

@TypedShellRoute<_SingleRoutes>(routes: <TypedRoute<RouteData>>[
  TypedGoRoute<LoginRoute>(path: LoginRoute.path),
  TypedGoRoute<NowRoute>(path: NowRoute.path),
  TypedStatefulShellRoute<_TabbedRoutes>(
    branches: [
      TypedStatefulShellBranch<PrioritiesBranch>(
        routes: <TypedGoRoute<GoRouteData>>[
          TypedGoRoute<PrioritiesRoute>(path: PrioritiesRoute.path),
          TypedGoRoute<NewPriorityRoute>(path: NewPriorityRoute.path),
          TypedGoRoute<PriorityRoute>(path: PriorityRoute.path, routes: [
            TypedGoRoute<NewActivityRoute>(path: NewActivityRoute.path),
            TypedGoRoute<ActivityRoute>(path: ActivityRoute.path),
          ]),
        ],
      ),
      TypedStatefulShellBranch<ScheduleBranch>(
        routes: <TypedGoRoute<GoRouteData>>[
          TypedGoRoute<ScheduleRoute>(path: ScheduleRoute.path, routes: [
            TypedGoRoute<NewEventRoute>(path: NewEventRoute.path),
            TypedGoRoute<EventRoute>(path: EventRoute.path),
          ]),
        ],
      ),
    ],
  ),
])
@immutable
class _SingleRoutes extends ShellRouteData {
  const _SingleRoutes();

  @override
  Widget builder(BuildContext context, GoRouterState state, Widget child) {
    return child;
  }
}

@immutable
class _TabbedRoutes extends StatefulShellRouteData {
  const _TabbedRoutes();

  @override
  Widget builder(
    BuildContext context,
    GoRouterState state,
    StatefulNavigationShell navigationShell,
  ) {
    return TabbedLayout(
      navigationShell,
      navigationShell: navigationShell,
    );
  }
}

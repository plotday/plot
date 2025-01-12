import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'widget/widget.dart';
import 'router.dart';

part 'router_tabbed.g.dart';

@TypedShellRoute<_SingleRoutes>(routes: <TypedRoute<RouteData>>[
  TypedGoRoute<LoginRoute>(path: LoginRoute.path),
  TypedStatefulShellRoute<_TabbedRoutes>(
    branches: [
      TypedStatefulShellBranch<PrioritiesBranch>(
        routes: <TypedGoRoute<GoRouteData>>[
          TypedGoRoute<PrioritiesRoute>(
            path: PrioritiesRoute.path,
          ),
          TypedGoRoute<PriorityRoute>(
            path: PriorityRoute.path,
          ),
        ],
      ),
      TypedStatefulShellBranch<ScheduleBranch>(
        routes: <TypedGoRoute<GoRouteData>>[
          TypedGoRoute<PrioritiesRoute>(
            path: PrioritiesRoute.path,
          ),
        ],
      ),
      TypedStatefulShellBranch<MoreBranch>(
        routes: <TypedGoRoute<GoRouteData>>[
          TypedGoRoute<SettingsRoute>(path: SettingsRoute.path),
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

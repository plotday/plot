import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'widget/widget.dart';
import 'page/page.dart';
import 'router.dart';
import 'widget/global_menu.dart';
import 'command/global.dart';

part 'router_adaptive.g.dart';

@TypedShellRoute<_AdaptiveRoutes>(routes: <TypedRoute<RouteData>>[
  TypedGoRoute<LoginRoute>(path: LoginRoute.path),
  TypedShellRoute<_PrioritiesRoutes>(routes: <TypedRoute<RouteData>>[
    TypedGoRoute<PrioritiesRoute>(path: PrioritiesRoute.path),
  ]),
  TypedShellRoute<_PriorityRoutes>(routes: <TypedRoute<RouteData>>[
    TypedGoRoute<NewPriorityRoute>(path: NewPriorityRoute.path),
    TypedGoRoute<PriorityRoute>(path: PriorityRoute.path, routes: [
      TypedGoRoute<NewActivityRoute>(path: NewActivityRoute.path),
      TypedGoRoute<ActivityRoute>(path: ActivityRoute.path),
    ]),
    TypedGoRoute<ScheduleRoute>(path: ScheduleRoute.path, routes: [
      TypedGoRoute<NewEventRoute>(path: NewEventRoute.path),
      TypedGoRoute<EventRoute>(path: EventRoute.path),
    ]),
  ]),
])
@immutable
class _AdaptiveRoutes extends ShellRouteData {
  const _AdaptiveRoutes();

  @override
  Widget builder(BuildContext context, GoRouterState state, Widget child) {
    return GlobalShortcuts(
      child: GlobalMenu(child: child),
    );
  }
}

@immutable
class _PrioritiesRoutes extends ShellRouteData {
  const _PrioritiesRoutes();

  @override
  Widget builder(BuildContext context, GoRouterState state, Widget child) {
    return SidebarLayout(
      const PrioritiesNav(),
      child,
      const SchedulePage(),
      header: const PrioritiesHeader(),
    );
  }
}

@immutable
class _PriorityRoutes extends ShellRouteData {
  const _PriorityRoutes();

  @override
  Widget builder(BuildContext context, GoRouterState state, Widget child) {
    return SidebarLayout(
      const PriorityPage(),
      child,
      const SchedulePage(),
      header: const PriorityHeader(),
    );
  }
}

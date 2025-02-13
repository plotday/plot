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
  TypedGoRoute<NowRoute>(path: NowRoute.path),
  TypedShellRoute<_PriorityRoutes>(routes: <TypedRoute<RouteData>>[
    TypedGoRoute<PrioritiesRoute>(path: PrioritiesRoute.path),
    TypedGoRoute<NewPriorityRoute>(path: NewPriorityRoute.path),
    TypedGoRoute<ScheduleRoute>(path: ScheduleRoute.path),
    TypedGoRoute<NewEventRoute>(path: NewEventRoute.path),
    TypedGoRoute<EventRoute>(path: EventRoute.path),
    TypedGoRoute<PriorityRoute>(path: PriorityRoute.path, routes: [
      TypedGoRoute<NewActivityRoute>(path: NewActivityRoute.path),
      TypedGoRoute<ActivityRoute>(path: ActivityRoute.path),
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
class _PriorityRoutes extends ShellRouteData {
  const _PriorityRoutes();

  @override
  Widget builder(BuildContext context, GoRouterState state, Widget child) {
    return SidebarLayout(
      const PrioritiesPage(),
      child,
      const SchedulePage(),
      header: const PriorityHeader(),
    );
  }
}

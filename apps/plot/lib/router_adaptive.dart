import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'widget/widget.dart';
import 'command/global.dart';
import 'page/page.dart';
import 'state/priority.dart';
import 'router.dart';

part 'router_adaptive.g.dart';

@TypedShellRoute<_AdaptiveRoutes>(routes: <TypedRoute<RouteData>>[
  TypedGoRoute<LoginRoute>(path: LoginRoute.path),
  TypedShellRoute<_TripleRoutes>(routes: <TypedRoute<RouteData>>[
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
    return child;
  }
}

@immutable
class _TripleRoutes extends ShellRouteData {
  const _TripleRoutes();

  @override
  Widget builder(BuildContext context, GoRouterState state, Widget child) {
    return GlobalShortcuts(
      child: SidebarLayout(
        const PriorityPage(),
        child,
        const SchedulePage(),
        header: BlocBuilder<PriorityBloc, PriorityState>(
          builder: (context, state) => GlobalHeader(
            priorities: state.rootPriorities,
            currentPriority: state.current,
            balances: state.balances?[state.current?.id],
            isNow: state.week.isNow(),
            onCurrentPrioritySelected: (priority) {
              PriorityRoute.byId(priority?.id).go(context);
            },
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'widget/widget.dart';
import 'page/page.dart';
import 'state/activity.dart';
import 'router.dart';

part 'router_adaptive.g.dart';

@TypedShellRoute<_AdaptiveRoutes>(routes: <TypedRoute<RouteData>>[
  TypedGoRoute<LoginRoute>(path: LoginRoute.path),
  TypedGoRoute<SettingsRoute>(path: SettingsRoute.path),
  TypedShellRoute<_TripleRoutes>(routes: <TypedRoute<RouteData>>[
    TypedGoRoute<HomeRoute>(path: HomeRoute.path),
    TypedGoRoute<NewEventRoute>(path: NewEventRoute.path),
    TypedGoRoute<EventRoute>(path: EventRoute.path),
    TypedGoRoute<ActivityRoute>(path: ActivityRoute.path),
    TypedGoRoute<NewRoute>(path: NewRoute.path), // TODO redirect
    TypedGoRoute<ActivityAddRoute>(path: ActivityAddRoute.path),
    TypedGoRoute<TopicRoute>(path: TopicRoute.path),
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
    return SidebarLayout(
      const ActivityPage(),
      child,
      const SchedulePage(),
      title: BlocBuilder<ActivityBloc, ActivityState>(
        builder: (context, state) => Header(
          activities: state.rootActivities,
          currentActivity: state.current,
          balances: state.balances?[state.current?.id],
          isNow: state.week.isNow(),
          onCurrentActivitySelected: (activity) {
            ActivityRoute.byId(activity?.id).go(context);
          },
        ),
      ),
    );
  }
}

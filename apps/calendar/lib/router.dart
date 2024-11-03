import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'store/store.dart';
import 'state/user.dart';
import 'state/schedule.dart';
import 'state/activity.dart';
import 'state/root_provider.dart';
import 'page/page.dart';
import 'widget/layout.dart';

part 'router.g.dart';

@immutable
abstract class Route extends GoRouteData with EquatableMixin {
  static Route? _last;

  const Route();

  @override
  Widget build(BuildContext context, GoRouterState state) {
    _onBuild(context);
    // TODO get layout from context
    return buildAdaptive(context, state);
  }

  Widget buildAdaptive(BuildContext context, GoRouterState state);
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      buildAdaptive(context, state);

  void onEnter(BuildContext context) {}

  void _onBuild(BuildContext context) {
    if (_last != this) {
      _last = this;
      onEnter(context);
    }
  }
}

@immutable
class LoginRoute extends Route {
  static const path = '/login';

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const SignInPage();

  @override
  List<Object?> get props => [];
}

@immutable
class SettingsRoute extends Route {
  static const path = '/settings';

  const SettingsRoute();

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const AccountPage();

  @override
  List<Object?> get props => [];
}

@immutable
class HomeRoute extends Route {
  static const path = '/';

  HomeRoute({this.d}) : day = d == null ? Date.today() : Date.fromString(d);
  const HomeRoute.day(this.day) : d = null;

  final Date day;
  final String? d;

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const TopicPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const SchedulePage();

  @override
  List<Object?> get props => [];
}

@immutable
class EventRoute extends Route {
  static const path = '/schedule/:eventId';

  const EventRoute({required this.eventId});

  final String eventId;

  @override
  void onEnter(BuildContext context) async {
    final event =
        await context.read<ScheduleBloc>().selectById(Uuid.fromString(eventId));
    if (!context.mounted) return;
    context.read<ActivityBloc>().setCurrent(event.activityId);
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const EventPage();

  @override
  List<Object?> get props => [eventId];
}

@immutable
class ActivityRoute extends Route {
  static const path = '/activity/:activityIdString';
  static const rootId = 'root';

  ActivityRoute({required this.activityIdString})
      : activityId = activityIdString == rootId
            ? null
            : Uuid.fromString(activityIdString);
  ActivityRoute.byId(this.activityId)
      : activityIdString = activityId?.toString() ?? rootId;
  const ActivityRoute.root()
      : activityIdString = rootId,
        activityId = null;

  final String activityIdString;
  final ActivityId? activityId;

  @override
  void onEnter(BuildContext context) {
    context.read<ActivityBloc>().setCurrent(activityId);
    final event = context.read<ScheduleBloc>().selected;
    if (event != null) {
      context
          .read<ScheduleBloc>()
          .update(event.copyWith(activityId: Value(activityId)));
    }
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const TopicPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const ActivityPage();

  @override
  List<Object?> get props => [activityId];
}

@immutable
class TopicRoute extends ActivityRoute {
  static const path = '${ActivityRoute.path}/$subPath';
  static const subPath = ':topicIdString';

  TopicRoute({required this.activityIdString, required this.topicIdString})
      : topicId = TopicId.fromString(topicIdString),
        super(activityIdString: activityIdString);
  TopicRoute.byId(ActivityId? activityId, this.topicId)
      : activityIdString = activityId?.toString() ?? ActivityRoute.rootId,
        topicIdString = topicId.toString(),
        super.byId(activityId);

  final String activityIdString;
  final String topicIdString;
  final TopicId? topicId;

  @override
  void onEnter(BuildContext context) {
    super.onEnter(context);
    context.read<ActivityBloc>().setTopic(topicId);
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const TopicPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const ActivityPage();

  @override
  List<Object?> get props => super.props + [topicId];
}

@immutable
class ActivityAddRoute extends ActivityRoute {
  static const path = '${ActivityRoute.path}/$subPath';
  static const subPath = 'new';

  ActivityAddRoute({required this.activityIdString})
      : super(activityIdString: activityIdString);
  ActivityAddRoute.byId(ActivityId? activityId)
      : activityIdString = activityId?.toString() ?? ActivityRoute.rootId,
        super.byId(activityId);

  final String activityIdString;

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const ActivityEditPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const ActivityEditPage();
}

@immutable
class ActivityEditRoute extends ActivityRoute {
  static const path = '${ActivityRoute.path}/$subPath';
  static const subPath = 'edit';

  ActivityEditRoute({required this.activityIdString})
      : super(activityIdString: activityIdString);
  ActivityEditRoute.byId(ActivityId activityId)
      : activityIdString = activityId?.toString() ?? ActivityRoute.rootId,
        super.byId(activityId);

  final String activityIdString;

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const ActivityEditPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const ActivityEditPage();
}

class ActivityBranch extends StatefulShellBranchData {
  const ActivityBranch();
}

class ScheduleBranch extends StatefulShellBranchData {
  const ScheduleBranch();
}

class MoreBranch extends StatefulShellBranchData {
  const MoreBranch();
}

@TypedShellRoute<_AdaptiveRoutes>(routes: <TypedRoute<RouteData>>[
  TypedGoRoute<LoginRoute>(path: LoginRoute.path),
  TypedGoRoute<SettingsRoute>(path: SettingsRoute.path),
  TypedShellRoute<_TripleRoutes>(routes: <TypedRoute<RouteData>>[
    TypedGoRoute<HomeRoute>(path: HomeRoute.path),
    TypedGoRoute<EventRoute>(path: EventRoute.path),
    TypedGoRoute<ActivityRoute>(path: ActivityRoute.path),
    TypedGoRoute<ActivityEditRoute>(path: ActivityEditRoute.path),
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
    return AdaptiveLayout(
      const SchedulePage(),
      const ActivityPage(),
      child,
    );
  }
}

@TypedShellRoute<_SingleRoutes>(routes: <TypedRoute<RouteData>>[
  TypedGoRoute<LoginRoute>(path: LoginRoute.path),
  TypedStatefulShellRoute<_TabbedRoutes>(
    branches: [
      TypedStatefulShellBranch<ScheduleBranch>(
        routes: <TypedGoRoute<GoRouteData>>[
          TypedGoRoute<HomeRoute>(
            path: HomeRoute.path,
            routes: [
              TypedGoRoute<EventRoute>(
                path: EventRoute.path,
              ),
            ],
          ),
        ],
      ),
      TypedStatefulShellBranch<ActivityBranch>(
        routes: <TypedGoRoute<GoRouteData>>[
          TypedGoRoute<ActivityRoute>(
            path: ActivityRoute.path,
            routes: [
              TypedGoRoute<ActivityEditRoute>(path: ActivityEditRoute.subPath),
              TypedGoRoute<ActivityAddRoute>(path: ActivityAddRoute.subPath),
              TypedGoRoute<TopicRoute>(
                path: TopicRoute.subPath,
              ),
            ],
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

GoRouter getRouter(PanelLayout layout) {
  return GoRouter(
    routes: [
      ShellRoute(
        builder: (context, state, child) {
          return RootProvider(
            key: const Key('RootProvider'),
            child: child,
          );
        },
        routes: layout == PanelLayout.adaptive
            ? [$_AdaptiveRoutes]
            : [$_SingleRoutes],
      ),
    ],
    redirect: (BuildContext context, GoRouterState state) async {
      // Using `of` method creates a dependency of StreamAuthScope. It will
      // cause go_router to reparse current route if StreamAuth has new sign-in
      // information.
      final bool loggedIn = context.read<UserBloc>().state is UserSignedIn;
      final bool loggingIn = state.matchedLocation == '/login';
      if (!loggedIn) {
        return LoginRoute.path;
      }

      // if the user is logged in but still on the login page, send them to
      // the home page
      if (loggingIn) {
        return HomeRoute.path;
      }

      // no need to redirect at all
      return null;
    },
  );
}

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'store/store.dart';
import 'state/user.dart';
import 'state/schedule.dart';
import 'state/activity.dart';
import 'state/now.dart';
import 'page/page.dart';
import 'widget/widget.dart';
import "router_tabbed.dart" show $_SingleRoutes;
import "router_adaptive.dart";

export "router_adaptive.dart";

@immutable
abstract class Route extends GoRouteData with EquatableMixin {
  static Route? _last;

  const Route();

  @override
  Widget build(BuildContext context, GoRouterState state) {
    _onEnter(context);
    switch (Layout.layout) {
      case PanelLayout.sidebar:
        return buildAdaptive(context, state);
      case PanelLayout.tabbed:
        return buildSingle(context, state);
    }
  }

  @override
  FutureOr<String?> redirect(BuildContext context, GoRouterState state) {
    _onEnter(context);
    return super.redirect(context, state);
  }

  Widget buildAdaptive(BuildContext context, GoRouterState state);
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      buildAdaptive(context, state);

  void onEnter(BuildContext context) {}

  void _onEnter(BuildContext context) {
    if (_last != this) {
      _last = this;
      onEnter(context);
    }
  }
}

@immutable
class LoginRoute extends Route {
  static const path = '/login';

  const LoginRoute();

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
  Widget buildAdaptive(BuildContext context, GoRouterState state) {
    return const AccountPage();
  }

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
  void onEnter(BuildContext context) {
    context.read<ActivityBloc>()
      ..setCurrent(null)
      ..setTopic(null);
    context.read<NowBloc>().setActivity(null);
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const NewPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const SchedulePage();

  @override
  List<Object?> get props => [];
}

@immutable
class NewEventRoute extends Route {
  static const path = '/schedule/new';

  NewEventRoute({
    this.name,
    this.at,
  }) : _at = at == null ? null : DateTimeRange.fromString(at);

  NewEventRoute.at(
    this._at, {
    this.name,
  }) : at = _at?.toDb();

  final String? at;
  final DateTimeRange? _at;
  final String? name;

  @override
  void onEnter(BuildContext context) async {
    context.read<ScheduleBloc>().select(
          Event(
            name: name,
            at: _at ?? Day.today().toDateTimeRange(),
            draft: true,
          ),
        );
  }

  @override
  FutureOr<String?> redirect(BuildContext context, GoRouterState state) async {
    final ret = await super.redirect(context, state);
    if (ret != null) return ret;
    if (Layout.layout == PanelLayout.sidebar && context.mounted) {
      return ActivityRoute.byId(context.read<ActivityBloc>().state.current?.id)
          .location;
    }
    return null;
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const EventPage();

  @override
  List<Object?> get props => [at, name];
}

@immutable
class EventRoute extends Route {
  static const path = '/schedule/:eventIdString';

  EventRoute({required this.eventIdString})
      : eventId = Uuid.fromString(eventIdString);
  EventRoute.byId(this.eventId) : eventIdString = eventId.toString();

  final String eventIdString;
  final EventId eventId;

  @override
  void onEnter(BuildContext context) async {
    final event = await context.read<ScheduleBloc>().selectById(eventId);
    if (!context.mounted) return;
    context.read<ActivityBloc>().setCurrentId(event.activityId);
  }

  @override
  FutureOr<String?> redirect(BuildContext context, GoRouterState state) async {
    final ret = await super.redirect(context, state);
    if (ret != null) return ret;
    if (Layout.layout == PanelLayout.sidebar && context.mounted) {
      return ActivityRoute.byId(context.read<ActivityBloc>().state.current?.id)
          .location;
    }
    return null;
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const EventPage();

  @override
  List<Object?> get props => [eventId];
}

@immutable
class ActivitiesRoute extends Route {
  static const path = '/activity';

  const ActivitiesRoute();

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const Spinner();

  @override
  List<Object?> get props => [];
}

@immutable
class ActivityRoute extends ActivitiesRoute {
  static const path = '${ActivitiesRoute.path}/$subPath';
  static const subPath = ':activityIdString';
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
  void onEnter(BuildContext context) async {
    context.read<ActivityBloc>().setCurrentId(activityId);
    if (activityId == null) {
      context.read<NowBloc>().setActivity(null);
      return;
    }
    Activity activity = await Activity.get(activityId!);
    if (!context.mounted) return;
    context.read<NowBloc>().setActivity(activity);
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const NewPage();

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
      const NewPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const NewPage();
}

@immutable
class NewRoute extends ActivityRoute {
  static const path = '${ActivityRoute.path}/$subPath';
  static const subPath = 'new';

  NewRoute({required this.activityIdString})
      : super(activityIdString: activityIdString);
  NewRoute.byId(ActivityId activityId)
      : activityIdString = activityId?.toString() ?? ActivityRoute.rootId,
        super.byId(activityId);

  final String activityIdString;

  @override
  void onEnter(BuildContext context) {
    super.onEnter(context);
    context.read<ActivityBloc>().setTopic(null);
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const NewPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const NewPage();
}

class ActivityBranch extends StatefulShellBranchData {
  const ActivityBranch();
}

class NewBranch extends StatefulShellBranchData {
  const NewBranch();
}

class ScheduleBranch extends StatefulShellBranchData {
  const ScheduleBranch();
}

class MoreBranch extends StatefulShellBranchData {
  const MoreBranch();
}

GoRouter getRouter(PanelLayout layout) {
  return GoRouter(
    routes:
        layout == PanelLayout.sidebar ? [$_AdaptiveRoutes] : [$_SingleRoutes],
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

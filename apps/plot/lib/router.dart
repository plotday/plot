import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'store/store.dart';
import 'state/user.dart';
import 'state/schedule.dart';
import 'state/priority.dart';
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
class ScheduleRoute extends Route {
  static const path = '/schedule';

  ScheduleRoute({this.d}) : day = d == null ? Date.today() : Date.fromString(d);
  const ScheduleRoute.day(this.day) : d = null;

  final Date day;
  final String? d;

  @override
  void onEnter(BuildContext context) {
    context.read<PriorityBloc>()
      ..setCurrent(null)
      ..setActivity(null);
    context.read<NowBloc>().setPriority(null);
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
class EventRoute extends Route {
  static const path = ':eventIdString';

  EventRoute({required this.eventIdString})
      : eventId = Uuid.fromShortString(eventIdString);
  EventRoute.byId(this.eventId) : eventIdString = eventId.toShortString();

  final String eventIdString;
  final EventId eventId;

  @override
  void onEnter(BuildContext context) async {
    final event = await context.read<ScheduleBloc>().selectById(eventId);
    if (!context.mounted) return;
    context.read<PriorityBloc>().setCurrentId(event.priorityId);
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const NewPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const EventPage();

  @override
  List<Object?> get props => [eventId];
}

@immutable
class NewEventRoute extends Route {
  static const path = 'new';

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
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const NewPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const EventPage();

  @override
  List<Object?> get props => [at, name];
}

@immutable
class PriorityRoute extends Route {
  static const path = '/priorities/:priorityIdString';
  static const _root = 'top';

  PriorityRoute({required this.priorityIdString})
      : priorityId = priorityIdString == _root
            ? null
            : Uuid.fromShortString(priorityIdString);
  PriorityRoute.byId(PriorityId? id)
      : priorityId = id,
        priorityIdString = id == null ? _root : id.toShortString();
  const PriorityRoute.root()
      : priorityId = null,
        priorityIdString = _root;

  final String priorityIdString;
  final PriorityId? priorityId;

  @override
  void onEnter(BuildContext context) async {
    context.read<PriorityBloc>().setCurrentId(priorityId);
    if (priorityId == null) {
      context.read<NowBloc>().setPriority(null);
      return;
    }
    Priority activity = await Priority.get(priorityId!);
    if (!context.mounted) return;
    context.read<NowBloc>().setPriority(activity);
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const NewPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const PriorityPage();

  @override
  List<Object?> get props => [priorityId];
}

@immutable
class NewPriorityRoute extends Route {
  static const path = '/priorities/new';

  const NewPriorityRoute({this.priorityIdString});
  NewPriorityRoute.byId(PriorityId? priorityId)
      : priorityIdString = priorityId?.toString();

  final String? priorityIdString;

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const NewPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const NewPage();

  @override
  List<Object?> get props => [priorityIdString];
}

@immutable
class ActivityRoute extends PriorityRoute {
  static const path = ':activityIdString';

  ActivityRoute(
      {required this.priorityIdString, required this.activityIdString})
      : activityId = ActivityId.fromShortString(activityIdString),
        super(priorityIdString: priorityIdString);
  ActivityRoute.byId(PriorityId? priorityId, ActivityId activityId)
      : priorityIdString = priorityId?.toShortString() ?? PriorityRoute._root,
        activityId = activityId,
        activityIdString = activityId.toShortString(),
        super.byId(priorityId);

  @override
  final String priorityIdString;

  final String activityIdString;
  final ActivityId? activityId;

  @override
  void onEnter(BuildContext context) {
    super.onEnter(context);
    context.read<PriorityBloc>().setActivityId(activityId);
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const ActivityPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const ActivityPage();

  @override
  List<Object?> get props => [activityId];
}

@immutable
class NewActivityRoute extends PriorityRoute {
  static const path = 'new';

  NewActivityRoute({required this.priorityIdString})
      : super(priorityIdString: priorityIdString);
  NewActivityRoute.byId(PriorityId? priorityId)
      : priorityIdString = priorityId?.toString() ?? PriorityRoute._root,
        super.byId(priorityId);

  @override
  final String priorityIdString;

  @override
  void onEnter(BuildContext context) {
    super.onEnter(context);
    context.read<PriorityBloc>().setActivity(null);
  }

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const NewPage();

  @override
  List<Object?> get props => [priorityIdString];
}

class PrioritiesBranch extends StatefulShellBranchData {
  const PrioritiesBranch();
}

class ScheduleBranch extends StatefulShellBranchData {
  const ScheduleBranch();
}

class NewBranch extends StatefulShellBranchData {
  const NewBranch();
}

class MoreBranch extends StatefulShellBranchData {
  const MoreBranch();
}

GoRouter getRouter(PanelLayout layout) {
  return GoRouter(
    routes:
        layout == PanelLayout.sidebar ? [$_AdaptiveRoutes] : [$_SingleRoutes],
    redirect: (BuildContext context, GoRouterState state) async {
      print(state.uri);
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
      if (loggingIn || state.fullPath == null || state.fullPath!.isEmpty) {
        return const PriorityRoute.root().location;
      }

      // no need to redirect at all
      return null;
    },
  );
}

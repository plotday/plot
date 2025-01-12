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
class PrioritiesRoute extends Route {
  static const path = '/';

  PrioritiesRoute({this.d})
      : day = d == null ? Date.today() : Date.fromString(d);
  const PrioritiesRoute.day(this.day) : d = null;
  factory PrioritiesRoute.byId(PriorityId? priorityId) =>
      priorityId == null ? PrioritiesRoute() : PriorityRoute.byId(priorityId);

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
class ScheduleRoute extends Route {
  static const path = '/';

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
      return PrioritiesRoute.byId(
              context.read<PriorityBloc>().state.current?.id)
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
    context.read<PriorityBloc>().setCurrentId(event.priorityId);
  }

  @override
  FutureOr<String?> redirect(BuildContext context, GoRouterState state) async {
    final ret = await super.redirect(context, state);
    if (ret != null) return ret;
    if (Layout.layout == PanelLayout.sidebar && context.mounted) {
      return PrioritiesRoute.byId(
              context.read<PriorityBloc>().state.current?.id)
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
class PriorityRoute extends PrioritiesRoute {
  static const path = '/priority/:priorityIdString';

  PriorityRoute({required this.priorityIdString})
      : priorityId = Uuid.fromString(priorityIdString);
  PriorityRoute.byId(PriorityId id)
      : priorityId = id,
        priorityIdString = id.toString();

  final String priorityIdString;
  final PriorityId priorityId;

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
class ActivityRoute extends Route {
  static const path = '/activity/:activityIdString';

  ActivityRoute({required this.activityIdString})
      : activityId = ActivityId.fromString(activityIdString);
  ActivityRoute.byId(PriorityId? priorityId, this.activityId)
      : activityIdString = activityId.toString();

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
      const PriorityPage();

  @override
  List<Object?> get props => [activityId];
}

@immutable
class NewActivityRoute extends Route {
  static const path = '/activity/new';

  const NewActivityRoute();
  const NewActivityRoute.byId(PriorityId? priorityId);

  @override
  void onEnter(BuildContext context) {
    super.onEnter(context);
    context.read<PriorityBloc>().setActivity(null);
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const ActivityPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const PriorityPage();

  @override
  List<Object?> get props => [];
}

@immutable
class NewPriorityRoute extends Route {
  static const path = '/priority/new';

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

class PrioritiesBranch extends StatefulShellBranchData {
  const PrioritiesBranch();
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
        return PrioritiesRoute.path;
      }

      // no need to redirect at all
      return null;
    },
  );
}

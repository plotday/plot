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

  Future<void> onEnter(BuildContext context) async {}

  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const SizedBox(
        width: 0,
        height: 0,
      );
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      buildAdaptive(context, state);

  FutureOr<String?> redirectAdaptive(
          BuildContext context, GoRouterState state) =>
      null;
  FutureOr<String?> redirectSingle(BuildContext context, GoRouterState state) =>
      null;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    switch (Layout.layout) {
      case PanelLayout.sidebar:
        return buildAdaptive(context, state);
      case PanelLayout.tabbed:
        return buildSingle(context, state);
    }
  }

  @override
  FutureOr<String?> redirect(BuildContext context, GoRouterState state) async {
    await _onEnter(context);
    if (!context.mounted) return null;
    switch (Layout.layout) {
      case PanelLayout.sidebar:
        return redirectAdaptive(context, state);
      case PanelLayout.tabbed:
        return redirectSingle(context, state);
    }
  }

  Future<void> _onEnter(BuildContext context) async {
    if (_last != this) {
      _last = this;
      await onEnter(context);
    } else {
      print('onEnter already called');
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
class ScheduleRoute extends Route {
  static const path = '/schedule';

  ScheduleRoute({this.d}) : day = d == null ? Date.today() : Date.fromString(d);
  const ScheduleRoute.day(this.day) : d = null;

  final Date day;
  final String? d;

  @override
  Future<void> onEnter(BuildContext context) async {
    context.read<PriorityBloc>()
      ..setCurrent(null)
      ..setActivity(null);
    context.read<NowBloc>().setPriority(null);
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const ActivityPage();

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
  Future<void> onEnter(BuildContext context) async {
    final event = await context.read<ScheduleBloc>().selectById(eventId);
    if (!context.mounted) return;
    await context.read<PriorityBloc>().setCurrentId(event.priorityId);
  }

  @override
  Future<String?> redirectAdaptive(
      BuildContext context, GoRouterState state) async {
    final priority =
        (context.read<PriorityBloc>().state as PrioritySelectedState).current;
    return PriorityRoute.byId(priority.id).location;
  }

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
  Future<void> onEnter(BuildContext context) async {
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
      const ActivityPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const EventPage();

  @override
  List<Object?> get props => [at, name];
}

@immutable
class PrioritiesRoute extends Route {
  static const path = '/priorities/:priorityIdString';
  static const _all = 'all';

  PrioritiesRoute({required this.priorityIdString})
      : priorityId = priorityIdString == _all
            ? null
            : Uuid.fromShortString(priorityIdString);
  PrioritiesRoute.byId(PriorityId? id)
      : priorityId = id,
        priorityIdString = id == null ? _all : id.toShortString();
  const PrioritiesRoute.all()
      : priorityId = null,
        priorityIdString = _all;

  final String priorityIdString;
  final PriorityId? priorityId;

  // @override
  // void onEnter(BuildContext context) async {
  //   context.read<PriorityBloc>().setCurrentId(priorityId);
  //   if (priorityId == null) {
  //     context.read<NowBloc>().setPriority(null);
  //     return;
  //   }
  //   Priority activity = await Priority.get(priorityId!);
  //   if (!context.mounted) return;
  //   context.read<NowBloc>().setPriority(activity);
  // }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const PrioritiesPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const Scaffold(body: PrioritiesPage());

  @override
  List<Object?> get props => [priorityId];
}

@immutable
class PriorityRoute extends Route {
  static const path = '/priority/:priorityIdString';

  PriorityRoute({required this.priorityIdString})
      : priorityId = Uuid.fromShortString(priorityIdString);
  PriorityRoute.byId(this.priorityId)
      : priorityIdString = priorityId.toShortString();

  final String priorityIdString;
  final PriorityId priorityId;

  @override
  Future<void> onEnter(BuildContext context) async {
    context.read<PriorityBloc>().setCurrentId(priorityId);
    Priority priority = await Priority.get(priorityId!);
    if (!context.mounted) return;
    context.read<NowBloc>().setPriority(priority);
  }

  @override
  Widget buildAdaptive(BuildContext context, GoRouterState state) =>
      const ActivityPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const Scaffold(header: PriorityHeader(), body: PriorityPage());

  @override
  List<Object?> get props => [priorityId];
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
      const ActivityPage();

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const ActivityPage();

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
  ActivityRoute.byId(PriorityId priorityId, ActivityId activityId)
      : priorityIdString = priorityId.toShortString(),
        activityId = activityId,
        activityIdString = activityId.toShortString(),
        super.byId(priorityId);

  @override
  final String priorityIdString;

  final String activityIdString;
  final ActivityId? activityId;

  @override
  Future<void> onEnter(BuildContext context) async {
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
  NewActivityRoute.byId(PriorityId priorityId)
      : priorityIdString = priorityId.toShortString(),
        super.byId(priorityId);

  @override
  final String priorityIdString;

  @override
  Future<void> onEnter(BuildContext context) async {
    await super.onEnter(context);
    if (!context.mounted) return;
    context.read<PriorityBloc>().setActivity(null);
  }

  @override
  Widget buildSingle(BuildContext context, GoRouterState state) =>
      const ActivityPage();

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
        return const PrioritiesRoute.all().location;
      }

      // no need to redirect at all
      return null;
    },
  );
}

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'store/store.dart';
import 'state/user.dart';
import 'state/schedule.dart';
import 'state/priority.dart';
import 'state/now.dart';
import 'state/onboarding.dart';
import 'page/page.dart';
import 'widget/widget.dart';

part 'router.g.dart';

@immutable
abstract class Route extends GoRouteData with EquatableMixin {
  const Route();

  Future<void> onEnter(BuildContext context) async {}

  @override
  FutureOr<String?> redirect(BuildContext context, GoRouterState state) async {
    await _onEnter(context);
    return null;
  }

  static Route? _last;

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
  Widget build(BuildContext context, GoRouterState state) => const SignInPage();

  @override
  List<Object?> get props => [];
}

@immutable
class OnboardingRoute extends Route {
  static const path = '/start';

  const OnboardingRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const OnboardingPage();

  @override
  List<Object?> get props => [];
}

@immutable
class ScheduleRoute extends Route {
  static const path = '/schedule';

  const ScheduleRoute();

  @override
  Future<void> onEnter(BuildContext context) async {
    context.read<PriorityBloc>()
      ..setCurrent(null)
      ..setActivity(null);
    context.read<NowBloc>().setPriority(null);
  }

  @override
  FutureOr<String?> redirect(BuildContext context, GoRouterState state) async {
    await super.redirect(context, state);
    return const NowRoute().location;
  }

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const SchedulePage();

  @override
  List<Object?> get props => [];
}

@immutable
class EventRoute extends Route {
  static const path = '/schedule/:eventIdString';

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
  Widget build(BuildContext context, GoRouterState state) => const EventPage();

  @override
  List<Object?> get props => [eventId];
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
  Widget build(BuildContext context, GoRouterState state) => const EventPage();

  @override
  List<Object?> get props => [at, name];
}

@immutable
class NowRoute extends Route {
  static const path = '/';

  const NowRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const NowPage();

  @override
  List<Object?> get props => [];
}

@immutable
class PrioritiesRoute extends Route {
  static const path = '/priorities';

  const PrioritiesRoute();

  @override
  Future<void> onEnter(BuildContext context) async {
    context.read<PriorityBloc>().setCurrent(null);
    context.read<NowBloc>().setPriority(null);
  }

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const PrioritiesPage();

  @override
  List<Object?> get props => [];
}

@immutable
class PriorityRoute extends Route {
  static const path = '/:priorityIdString';

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
  Widget build(BuildContext context, GoRouterState state) =>
      const PrioritiesPage();

  @override
  List<Object?> get props => [priorityId];
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
  Widget build(BuildContext context, GoRouterState state) =>
      const ActivityPage();

  @override
  List<Object?> get props => [priorityIdString];
}

@immutable
class NewPriorityRoute extends Route {
  static const path = '/priorities/new';

  const NewPriorityRoute({this.priorityIdString});
  NewPriorityRoute.byId(PriorityId? priorityId)
      : priorityIdString = priorityId?.toString();

  final String? priorityIdString;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const NewPriorityPage();

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
  ActivityRoute.byActivity(Activity activity)
      : priorityIdString = activity.priorityId.toShortString(),
        activityId = activity.id,
        activityIdString = activity.id.toShortString(),
        super.byId(activity.priorityId);
  ActivityRoute.byId({required PriorityId priorityId, required this.activityId})
      : priorityIdString = priorityId.toShortString(),
        activityIdString = activityId.toShortString(),
        super.byId(priorityId);

  @override
  final String priorityIdString;
  final String activityIdString;
  final ActivityId activityId;

  @override
  Future<void> onEnter(BuildContext context) async {
    super.onEnter(context);
    context.read<PriorityBloc>().setActivityId(activityId);
  }

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const ActivityPage();

  @override
  List<Object?> get props => [activityId];
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

class RouterBuilder extends StatefulWidget {
  final Widget Function(BuildContext, GoRouter) builder;

  const RouterBuilder({required this.builder, super.key});

  @override
  RouterBuilderState createState() => RouterBuilderState();
}

class RouterBuilderState extends State<RouterBuilder> {
  late GoRouter _router;
  Uri? redirectTo;

  @override
  void initState() {
    super.initState();
    _router = _createRouter();
  }

  GoRouter _createRouter() {
    return GoRouter(
      routes: [$_Routes],
      redirect: (BuildContext context, GoRouterState state) async {
        print(state.uri);

        if (context.read<UserBloc>().state is! UserSignedIn) {
          redirectTo ??= state.uri;
          return const LoginRoute().location;
        }

        if (context.read<OnboardingBloc>().state is! OnboardingCompleteState) {
          redirectTo ??= state.uri;
          return const OnboardingRoute().location;
        }

        if (['/login', '/start']
                .contains(redirectTo?.path ?? state.matchedLocation) ||
            state.fullPath == null ||
            state.fullPath!.isEmpty) {
          redirectTo = null;
          return const NowRoute().location;
        }

        if (redirectTo != null) {
          final uri = redirectTo!;
          redirectTo = null;
          return uri.toString();
        }

        // No redirect
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<UserBloc, UserState>(
      listener: (context, state) {
        _router.refresh();
      },
      builder: (context, state) {
        if (state is UserSignedIn) {
          return BlocListener<OnboardingBloc, OnboardingState>(
            listener: (context, state) {
              _router.refresh();
            },
            child: widget.builder(context, _router),
          );
        }
        return widget.builder(context, _router);
      },
    );
  }
}

@TypedShellRoute<_Routes>(routes: <TypedRoute<RouteData>>[
  TypedGoRoute<LoginRoute>(path: LoginRoute.path),
  TypedGoRoute<OnboardingRoute>(path: OnboardingRoute.path),
  TypedGoRoute<NowRoute>(path: NowRoute.path),
  TypedStatefulShellRoute<_TabbedRoutes>(
    branches: [
      TypedStatefulShellBranch<PrioritiesBranch>(
        routes: <TypedGoRoute<GoRouteData>>[
          TypedGoRoute<PrioritiesRoute>(path: PrioritiesRoute.path),
          TypedGoRoute<NewPriorityRoute>(path: NewPriorityRoute.path),
          TypedGoRoute<PriorityRoute>(path: PriorityRoute.path, routes: [
            TypedGoRoute<NewActivityRoute>(path: NewActivityRoute.path),
            TypedGoRoute<ActivityRoute>(path: ActivityRoute.path),
          ]),
        ],
      ),
      TypedStatefulShellBranch<ScheduleBranch>(
        routes: <TypedGoRoute<GoRouteData>>[
          TypedGoRoute<ScheduleRoute>(path: ScheduleRoute.path, routes: [
            TypedGoRoute<NewEventRoute>(path: NewEventRoute.path),
            TypedGoRoute<EventRoute>(path: EventRoute.path),
          ]),
        ],
      ),
    ],
  ),
])
@immutable
class _Routes extends ShellRouteData {
  const _Routes();

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
    return Layout(
      navigationShell,
      navigationShell: navigationShell,
    );
  }
}

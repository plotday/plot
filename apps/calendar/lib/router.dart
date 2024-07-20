import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'model/context.dart';
import 'state/user.dart';
import 'state/schedule.dart';
import 'state/context.dart';
import 'state/root_provider.dart';
import 'page/page.dart';
import 'widget/layout.dart';
import 'util/time.dart';
import 'util/optional.dart';

part 'router.g.dart';

class NavigationContext extends InheritedWidget {
  static StatefulNavigationShell of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<NavigationContext>()!
        .navigationShell;
  }

  const NavigationContext({
    required this.navigationShell,
    required super.child,
    super.key,
  });
  final StatefulNavigationShell navigationShell;

  @override
  bool updateShouldNotify(NavigationContext oldWidget) {
    return navigationShell != oldWidget.navigationShell;
  }
}

@TypedGoRoute<LoginRoute>(path: '/login')
class LoginRoute extends GoRouteData {
  const LoginRoute();

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      const NoTransitionPage(
        child: SignInPage(),
      );
}

class SettingsRoute extends GoRouteData {
  const SettingsRoute();

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    return const NoTransitionPage(
      child: AccountPage(),
    );
  }
}

abstract class Route extends GoRouteData {
  void onBuild(BuildContext context) {
    if (!_init) {
      _init = true;
      onEnter(context);
    }
  }

  bool _init = false;

  void onEnter(BuildContext context) {}
}

abstract class AdaptiveRoute extends Route {
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    onBuild(context);
    return switch (Layout.getLayout(context)) {
      PanelLayout.single => buildSinglePage(context, state),
      PanelLayout.double => buildDoublePage(context, state),
      PanelLayout.triple => buildTriplePage(context, state),
    };
  }

  Page<void> buildSinglePage(BuildContext context, GoRouterState state);
  Page<void> buildDoublePage(BuildContext context, GoRouterState state);
  Page<void> buildTriplePage(BuildContext context, GoRouterState state);
}

@TypedGoRoute<HomeRoute>(path: '/', name: 'home:triple', routes: [
  TypedGoRoute<SettingsRoute>(path: 'settings'),
])
class HomeRoute extends AdaptiveRoute {
  @override
  void onEnter(BuildContext context) async {
    final event = await context.read<ScheduleBloc>().selectCurrent();
    if (!context.mounted) return;
    context.read<ContextBloc>().setCurrent(event.context);
  }

  @override
  Page<void> buildTriplePage(BuildContext context, GoRouterState state) =>
      const NoTransitionPage(
        child: TripleLayout(
          EventPage(),
          ContextPage(),
          NotesPage(),
        ),
      );

  @override
  Page<void> buildDoublePage(BuildContext context, GoRouterState state) =>
      const NoTransitionPage(
        child: DoubleLayout(
          EventPage(),
          ContextPage(),
        ),
      );

  @override
  Page<void> buildSinglePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: SingleLayout(
          const EventPage(),
          navigationShell: NavigationContext.of(context),
        ),
      );
}

@TypedGoRoute<ScheduleRoute>(path: '/d/:dayString', name: 'schedule:triple')
class ScheduleRoute extends AdaptiveRoute {
  ScheduleRoute({required this.dayString}) : day = Date.fromString(dayString);
  ScheduleRoute.day({required this.day}) : dayString = day.toString();

  final Date day;
  final String dayString;

  @override
  void onEnter(BuildContext context) async {
    // TODO
    print(day);
  }

  @override
  Page<void> buildSinglePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: SingleLayout(
          const SchedulePage(),
          navigationShell: NavigationContext.of(context),
        ),
      );

  @override
  Page<void> buildDoublePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: DoubleLayout(
          const SchedulePage(),
          const ContextPage(),
          navigationShell: NavigationContext.of(context),
        ),
      );

  @override
  Page<void> buildTriplePage(BuildContext context, GoRouterState state) =>
      const NoTransitionPage(
        child: TripleLayout(
          SchedulePage(),
          ContextPage(),
          NotesPage(),
        ),
      );
}

@TypedGoRoute<EventRoute>(path: '/e/:eventId', name: 'event:triple')
class EventRoute extends AdaptiveRoute {
  EventRoute({required this.eventId});

  final int eventId;

  @override
  void onEnter(BuildContext context) async {
    final event = await context.read<ScheduleBloc>().selectById(eventId);
    if (!context.mounted) return;
    context.read<ContextBloc>().setCurrent(event.context);
  }

  @override
  Page<void> buildSinglePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: SingleLayout(
          const EventPage(),
          navigationShell: NavigationContext.of(context),
        ),
      );

  @override
  Page<void> buildDoublePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: DoubleLayout(
          const EventPage(),
          const ContextPage(),
          navigationShell: NavigationContext.of(context),
        ),
      );

  @override
  Page<void> buildTriplePage(BuildContext context, GoRouterState state) =>
      const NoTransitionPage(
        child: TripleLayout(
          EventPage(),
          ContextPage(),
          NotesPage(),
        ),
      );
}

class PrioritiesRoute extends AdaptiveRoute {
  @override
  void onEnter(BuildContext context) {
    context.read<ContextBloc>().setCurrent(null);
    context
        .read<ScheduleBloc>()
        .selected
        ?.copyWith(context: Optional.of(null))
        .save();
  }

  @override
  Page<void> buildTriplePage(BuildContext context, GoRouterState state) =>
      const NoTransitionPage(
        child: TripleLayout(
          SchedulePage(),
          ContextPage(),
          NotesPage(),
        ),
      );

  @override
  Page<void> buildDoublePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: DoubleLayout(
          const ContextPage(),
          const SchedulePage(),
          navigationShell: NavigationContext.of(context),
        ),
      );

  @override
  Page<void> buildSinglePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: SingleLayout(
          const ContextPage(),
          navigationShell: NavigationContext.of(context),
        ),
      );
}

@TypedGoRoute<PriorityRoute>(path: '/p/:contextId', name: 'priority:triple')
class PriorityRoute extends AdaptiveRoute {
  PriorityRoute({required this.contextId})
      : context = Context.store.get(contextId);

  final int contextId;
  final Context context;

  @override
  void onEnter(BuildContext context) {
    context.read<ContextBloc>().setCurrent(this.context);
    context
        .read<ScheduleBloc>()
        .selected
        ?.copyWith(context: Optional.of(this.context))
        .save();
  }

  @override
  Page<void> buildTriplePage(BuildContext context, GoRouterState state) =>
      const NoTransitionPage(
        child: TripleLayout(
          SchedulePage(),
          ContextPage(),
          NotesPage(),
        ),
      );

  @override
  Page<void> buildDoublePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: DoubleLayout(
          const ContextPage(),
          const SchedulePage(),
          navigationShell: NavigationContext.of(context),
        ),
      );

  @override
  Page<void> buildSinglePage(BuildContext context, GoRouterState state) =>
      NoTransitionPage(
        child: SingleLayout(
          const ContextPage(),
          navigationShell: NavigationContext.of(context),
        ),
      );
}

class PrioritiesBranch extends StatefulShellBranchData {
  const PrioritiesBranch();
}

class ScheduleBranch extends StatefulShellBranchData {
  const ScheduleBranch();
}

@TypedStatefulShellRoute<_SingleRoutes>(
  branches: [
    TypedStatefulShellBranch<ScheduleBranch>(
      routes: <TypedGoRoute<GoRouteData>>[
        TypedGoRoute<HomeRoute>(
          path: '/',
          name: 'home:single',
          routes: [
            TypedGoRoute<EventRoute>(
              path: 'e/:eventId',
              name: 'event:single',
            ),
          ],
        ),
      ],
    ),
    TypedStatefulShellBranch<PrioritiesBranch>(
      routes: <TypedGoRoute<GoRouteData>>[
        TypedGoRoute<PrioritiesRoute>(
          path: '/p',
          name: 'priorities:single',
          routes: [
            TypedGoRoute<PriorityRoute>(
              path: ':contextId',
              name: 'priority:single',
            ),
          ],
        ),
      ],
    ),
  ],
)
class _SingleRoutes extends StatefulShellRouteData {
  const _SingleRoutes();

  @override
  Widget builder(
    BuildContext context,
    GoRouterState state,
    StatefulNavigationShell navigationShell,
  ) {
    return NavigationContext(
      navigationShell: navigationShell,
      child: navigationShell,
    );
  }
}

List<RouteBase> _filterRoutes(PanelLayout layout) => $appRoutes
    .where((route) =>
        route is! GoRoute ||
        route.name?.contains(':') != true ||
        route.name?.endsWith(":${layout.name}") == true)
    .toList();

RoutingConfig getRoutingConfig(PanelLayout layout) {
  return RoutingConfig(
    routes: [
      ShellRoute(
        builder: (context, state, child) {
          return RootProvider(
            key: const Key('RootProvider'),
            child: child,
          );
        },
        routes: _filterRoutes(layout),
      ),
    ],
    redirect: (BuildContext context, GoRouterState state) async {
      // Using `of` method creates a dependency of StreamAuthScope. It will
      // cause go_router to reparse current route if StreamAuth has new sign-in
      // information.
      final bool loggedIn = context.read<UserBloc>().state is UserSignedIn;
      final bool loggingIn = state.matchedLocation == '/login';
      if (!loggedIn) {
        return '/login';
      }

      // if the user is logged in but still on the login page, send them to
      // the home page
      if (loggingIn) {
        return '/';
      }

      // no need to redirect at all
      return null;
    },
  );
}

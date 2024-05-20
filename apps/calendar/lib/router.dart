import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'state/user.dart';
import 'state/root_provider.dart';
import 'page/sign_in.dart';
import 'page/schedule.dart';
import 'page/priority.dart';
import 'page/event.dart';
import 'platform/layout.dart';

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

final _singleRoutes = [
  StatefulShellRoute.indexedStack(
      builder: (BuildContext context, GoRouterState state,
          StatefulNavigationShell navigationShell) {
        return NavigationContext(
          navigationShell: navigationShell,
          child: navigationShell,
        );
      },
      branches: <StatefulShellBranch>[
        // The route branch for the first tab of the bottom navigation bar.
        StatefulShellBranch(
            // navigatorKey: _sectionANavigatorKey,
            routes: <RouteBase>[
              GoRoute(
                path: '/',
                pageBuilder: (context, state) {
                  return NoTransitionPage(
                    child: SingleLayout(
                      NavigationContext.of(context),
                      const SchedulePage(),
                    ),
                  );
                },
              ),
            ])
      ])
];

final _doubleRoutes = [
  GoRoute(
    path: '/',
    pageBuilder: (context, state) {
      return NoTransitionPage(
        child: DoubleLayout(NavigationContext.of(context), const SchedulePage(),
            const PriorityPage()),
      );
    },
  ),
];

final _tripleRoutes = [
  GoRoute(
    path: '/',
    pageBuilder: (context, state) {
      return const NoTransitionPage(
        child: TripleLayout(SchedulePage(), PriorityPage(), EventPage()),
      );
    },
  ),
];

PanelLayout? _lastLayout;
GoRouter? _layout;

GoRouter getRouter(BuildContext context) {
  final layout = Layout.getLayout(context);
  if (_lastLayout != layout) {
    _lastLayout = layout;
    _layout = GoRouter(
      routes: [
        ShellRoute(
          builder: (context, state, child) {
            return RootProvider(
              key: const Key('RootProvider'),
              child: child,
            );
          },
          routes: switch (layout) {
            PanelLayout.single => _singleRoutes,
            PanelLayout.double => _doubleRoutes,
            PanelLayout.triple => _tripleRoutes,
          },
        ),
        GoRoute(
          path: '/login',
          pageBuilder: (context, state) {
            return const NoTransitionPage(
              child: SignInPage(),
            );
          },
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
    print('Layout changed to $layout');
  }
  return _layout!;
}

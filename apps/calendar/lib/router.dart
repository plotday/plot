import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'model/session.dart' as plot_session;
import 'model/context.dart';
import 'state/priority.dart';
import 'state/context.dart';
import 'state/now.dart';
import 'state/user.dart';
import 'page/sign_in.dart';
import 'page/schedule.dart';
import 'page/priority.dart';
import 'page/event.dart';
import 'platform/layout.dart';

final _singleRoutes = [
  GoRoute(
    path: '/',
    pageBuilder: (context, state) {
      return const NoTransitionPage(
        child: Layout([SchedulePage()]),
      );
    },
  ),
];

final _doubleRoutes = [
  GoRoute(
    path: '/',
    pageBuilder: (context, state) {
      return const NoTransitionPage(
        child: Layout([SchedulePage(), PriorityPage()]),
      );
    },
  ),
];

final _tripleRoutes = [
  GoRoute(
    path: '/',
    pageBuilder: (context, state) {
      return const NoTransitionPage(
        child: Layout([SchedulePage(), PriorityPage(), EventPage()]),
      );
    },
  ),
];

GoRouter getRouter(BuildContext context) {
  final routes = switch (Layout.getLayout(context)) {
    PanelLayout.single => _singleRoutes,
    PanelLayout.double => _doubleRoutes,
    PanelLayout.triple => _tripleRoutes,
  };
  return GoRouter(
    routes: [
      ShellRoute(
        builder: (context, state, child) {
          return FutureBuilder(
            future: Future.wait(
                [Context.store.load(), plot_session.Session.store.load()]),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return MultiBlocProvider(
                providers: [
                  BlocProvider(create: (_) => PriorityBloc()),
                  BlocProvider(create: (_) => ContextBloc()),
                  BlocProvider(create: (_) => NowBloc()),
                ],
                child: child,
              );
            },
          );
        },
        routes: routes,
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
}

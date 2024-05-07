import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'util/async.dart';
import 'model/user.dart';
import 'model/session.dart' as plot_session;
import 'model/context.dart';
import 'state/priority.dart';
import 'state/context.dart';
import 'state/now.dart';
import 'page/sign_in.dart';
import 'layout.dart';

final router = GoRouter(
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
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (context, state) {
            return const NoTransitionPage(
              child: Layout(),
            );
          },
        ),
      ],
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
    final bool loggedIn = User.current != null;
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
  refreshListenable: StreamListenable<User?>(User.onCurrent).listenable,
);

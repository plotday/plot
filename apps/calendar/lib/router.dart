import 'package:go_router/go_router.dart';

import 'layout.dart';

final router = GoRouter(
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
);

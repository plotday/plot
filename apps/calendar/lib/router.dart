import 'package:go_router/go_router.dart';

import 'layout.dart';
import 'priority/page.dart';

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
    GoRoute(
      path: '/new',
      pageBuilder: (context, state) {
        return const NoTransitionPage(
          child: Layout(left: NewPriorityPage()),
        );
      },
    ),
  ],
);

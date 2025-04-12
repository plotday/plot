import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';
import 'package:platform_builder/platform_builder.dart';

import 'store/store.dart';
import 'state/user.dart';
import 'state/schedule.dart';
import 'state/priority.dart';
import 'state/now.dart';
import 'state/onboarding.dart';
import 'page/page.dart';
import 'widget/widget.dart';
import 'widget/window.dart';
import 'widget/global_menu.dart';
import 'command/global.dart';

part 'router.gr.dart';

// @immutable
// class NewEventRoute extends Route {
//   static const path = '/schedule/new';
//
//   NewEventRoute({
//     this.name,
//     this.at,
//   }) : _at = at == null ? null : DateTimeRange.fromString(at);
//
//   NewEventRoute.at(
//     this._at, {
//     this.name,
//   }) : at = _at?.toDb();
//
//   final String? at;
//   final DateTimeRange? _at;
//   final String? name;
//
//   @override
//   Future<void> onEnter(BuildContext context) async {
//     context.read<ScheduleBloc>().select(
//           Event(
//             name: name,
//             at: _at ?? Day.today().toDateTimeRange(),
//             draft: true,
//           ),
//         );
//   }
//
//   @override
//   Widget build(BuildContext context) => const EventPage();
//
//   @override
//   List<Object?> get props => [at, name];
// }

// class OnEnter extends AutoRouteGuard {
//   const OnEnter(this.onEnter);
//
//   final Future<void> Function(BuildContext context, RouteMatch<dynamic> route)
//       onEnter;
//
//   @override
//   void onNavigation(NavigationResolver resolver, StackRouter router) async {
//     await onEnter(resolver.context, resolver.route);
//     resolver.next(true);
//   }
// }

@RoutePage(name: 'AppShellRoute')
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return GlobalMenu(child: GlobalShortcuts(child: AutoRouter()));
  }
}

@AutoRouterConfig(generateForDir: ['lib', 'lib/page'])
class AppRouter extends RootStackRouter {
  @override
  RouteType get defaultRouteType => PlatformResolver.current(
    iOSResolver: () => RouteType.cupertino(),
    androidResolver: () => RouteType.material(),
    defaultResolver:
        () => RouteType.custom(
          duration: const Duration(milliseconds: 100),
          reverseDuration: const Duration(milliseconds: 10),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
  );

  @override
  List<AutoRoute> get routes => <AutoRoute>[
    AutoRoute(
      page: AppShellRoute.page,
      path: '/',
      children: [
        AutoRoute(
          page: EmptyShellRoute("Now"),
          path: '',
          guards: [
            AutoRouteGuardCallback((resolver, router) async {
              final priorityId =
                  resolver.context.read<NowBloc>().loadedState.priority.id;
              resolver.redirectUntil(PriorityRoute(priorityId: priorityId));
            }),
          ],
        ),
        AutoRoute(page: SignInRoute.page, path: 'login'),
        AutoRoute(page: OnboardingRoute.page, path: 'start'),
        AutoRoute(
          page: NewActivityRoute.page,
          path: 'new',
          children: [AutoRoute(page: NewActivityMainRoute.page, path: '')],
        ),
        // AutoRoute(page: NewPriorityRoute.page, path: 'priority/new'),
        AutoRoute(
          page: PriorityRoute.page,
          path: ':priorityId',
          children: [
            AutoRoute(page: PriorityMainRoute.page, path: ''),
            AutoRoute(
              page: ActivityRoute.page,
              path: ':activityId',
              children: [AutoRoute(page: ActivityMainRoute.page, path: '')],
            ),
          ],
        ),
      ],
    ),
    // children: [
    //   AutoRoute(
    //     page: ActivityRoute.page,
    //     path: ':activityId',
    //     guards: [
    //       OnEnter((context, route) async {
    //         context.read<PriorityBloc>().setActivityId(
    //             Uuid.fromShortString(
    //                 route.params.getString('activityId')));
    //       }),
    //     ],
    //   ),
    // ],
    // AutoRoute(
    //   page: PrioritiesRoute.page,
    //   path: '/priorities',
    //   guards: [
    //     OnEnter((context, route) async {
    //       context.read<PriorityBloc>().setCurrent(null);
    //       context.read<NowBloc>().setPriority(null);
    //     })
    //   ],
    //   children: [
    //     AutoRoute(page: NewPriorityRoute.page, path: '/priorities/new'),
    //   ],
    // ),
    // AutoRoute(
    //   page: ScheduleRoute.page,
    //   path: '/schedule',
    //   children: [
    //     AutoRoute(
    //       page: EventRoute.page,
    //       path: '/schedule/new',
    //       guards: [
    //         OnEnter((context, route) async {
    //           context.read<ScheduleBloc>().select(
    //                 Event(
    //                   name: name,
    //                   at: route._at ?? Day.today().toDateTimeRange(),
    //                   draft: true,
    //                 ),
    //               );
    //         })
    //       ],
    //     ),
    //     AutoRoute(
    //       page: EventRoute.page,
    //       path: '/schedule/:eventId',
    //       guards: [
    //         OnEnter((context, route) async {
    //           final event = await context.read<ScheduleBloc>().selectById(
    //               Uuid.fromShortString(route.params.getString('eventId')));
    //           if (!context.mounted) return;
    //           await context
    //               .read<PriorityBloc>()
    //               .setCurrentId(event.priorityId);
    //         })
    //       ],
    //   ),
    // ],
    // ),
  ];

  @override
  late final List<AutoRouteGuard> guards = [
    AutoRouteGuard.simple((resolver, router) {
      if (resolver.context.read<UserBloc>().state is! UserSignedIn) {
        resolver.redirectUntil(SignInRoute());
        return;
      }

      if (resolver.routeName == SignInRoute.name) {
        resolver.redirectUntil(PriorityRoute());
        return;
      }

      resolver.next();
    }),
  ];
}

extension FocusedRouterExtension on BuildContext {
  StackRouter get focusedRouter {
    var focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext?.router ?? router;
  }
}

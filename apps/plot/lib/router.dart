import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:platform_builder/platform_builder.dart';

import 'store/store.dart';
import 'state/now.dart';
import 'page/page.dart';
import 'widget/global_menu.dart';
import 'command/global.dart';

export 'package:auto_route/auto_route.dart';

part 'router.gr.dart';

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
        AutoRoute(
          page: ScheduleRoute.page,
          path: 'schedule',
          // children: [
          //   AutoRoute(
          //     page: EventRoute.page,
          //     path: '/schedule/new',
          //     guards: [
          //       OnEnter((context, route) async {
          //         context.read<ScheduleBloc>().select(
          //           Event(
          //             name: name,
          //             at: route._at ?? Day.today().toDateTimeRange(),
          //             draft: true,
          //           ),
          //         );
          //       }),
          //     ],
          //   ),
          //   AutoRoute(
          //     page: EventRoute.page,
          //     path: '/schedule/:eventId',
          //     guards: [
          //       OnEnter((context, route) async {
          //         final event = await context.read<ScheduleBloc>().selectById(
          //           Uuid.fromShortString(route.params.getString('eventId')),
          //         );
          //         if (!context.mounted) return;
          //         await context.read<PriorityBloc>().setCurrentId(
          //           event.priorityId,
          //         );
          //       }),
          //     ],
          //   ),
          // ],
        ),
        AutoRoute(
          page: PriorityRoute.page,
          path: ':priorityId',
          children: [AutoRoute(page: PriorityMainRoute.page, path: '')],
        ),
      ],
    ),
  ];
}

extension FocusedRouterExtension on BuildContext {
  StackRouter get focusedRouter {
    var focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext?.router ?? router;
  }
}

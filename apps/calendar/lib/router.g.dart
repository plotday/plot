// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'router.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [
      $loginRoute,
      $homeRoute,
      $scheduleRoute,
      $eventRoute,
      $priorityRoute,
      $_SingleRoutes,
    ];

RouteBase get $loginRoute => GoRouteData.$route(
      path: '/login',
      factory: $LoginRouteExtension._fromState,
    );

extension $LoginRouteExtension on LoginRoute {
  static LoginRoute _fromState(GoRouterState state) => const LoginRoute();

  String get location => GoRouteData.$location(
        '/login',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $homeRoute => GoRouteData.$route(
      path: '/',
      name: 'home:triple',
      factory: $HomeRouteExtension._fromState,
      routes: [
        GoRouteData.$route(
          path: 'settings',
          factory: $SettingsRouteExtension._fromState,
        ),
      ],
    );

extension $HomeRouteExtension on HomeRoute {
  static HomeRoute _fromState(GoRouterState state) => HomeRoute();

  String get location => GoRouteData.$location(
        '/',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

extension $SettingsRouteExtension on SettingsRoute {
  static SettingsRoute _fromState(GoRouterState state) => const SettingsRoute();

  String get location => GoRouteData.$location(
        '/settings',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $scheduleRoute => GoRouteData.$route(
      path: '/d/:dayString',
      name: 'schedule:triple',
      factory: $ScheduleRouteExtension._fromState,
    );

extension $ScheduleRouteExtension on ScheduleRoute {
  static ScheduleRoute _fromState(GoRouterState state) => ScheduleRoute(
        dayString: state.pathParameters['dayString']!,
      );

  String get location => GoRouteData.$location(
        '/d/${Uri.encodeComponent(dayString)}',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $eventRoute => GoRouteData.$route(
      path: '/e/:eventId',
      name: 'event:triple',
      factory: $EventRouteExtension._fromState,
    );

extension $EventRouteExtension on EventRoute {
  static EventRoute _fromState(GoRouterState state) => EventRoute(
        eventId: state.pathParameters['eventId']!,
      );

  String get location => GoRouteData.$location(
        '/e/${Uri.encodeComponent(eventId)}',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $priorityRoute => GoRouteData.$route(
      path: '/p/:contextId',
      name: 'priority:triple',
      factory: $PriorityRouteExtension._fromState,
    );

extension $PriorityRouteExtension on PriorityRoute {
  static PriorityRoute _fromState(GoRouterState state) => PriorityRoute(
        contextId: state.pathParameters['contextId']!,
      );

  String get location => GoRouteData.$location(
        '/p/${Uri.encodeComponent(contextId)}',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $_SingleRoutes => StatefulShellRouteData.$route(
      factory: $_SingleRoutesExtension._fromState,
      branches: [
        StatefulShellBranchData.$branch(
          routes: [
            GoRouteData.$route(
              path: '/',
              name: 'home:single',
              factory: $HomeRouteExtension._fromState,
              routes: [
                GoRouteData.$route(
                  path: 'e/:eventId',
                  name: 'event:single',
                  factory: $EventRouteExtension._fromState,
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranchData.$branch(
          routes: [
            GoRouteData.$route(
              path: '/p',
              name: 'priorities:single',
              factory: $PrioritiesRouteExtension._fromState,
              routes: [
                GoRouteData.$route(
                  path: ':contextId',
                  name: 'priority:single',
                  factory: $PriorityRouteExtension._fromState,
                ),
              ],
            ),
          ],
        ),
      ],
    );

extension $_SingleRoutesExtension on _SingleRoutes {
  static _SingleRoutes _fromState(GoRouterState state) => const _SingleRoutes();
}

extension $PrioritiesRouteExtension on PrioritiesRoute {
  static PrioritiesRoute _fromState(GoRouterState state) => PrioritiesRoute();

  String get location => GoRouteData.$location(
        '/p',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

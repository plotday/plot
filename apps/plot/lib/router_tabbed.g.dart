// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'router_tabbed.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [
      $_SingleRoutes,
    ];

RouteBase get $_SingleRoutes => ShellRouteData.$route(
      factory: $_SingleRoutesExtension._fromState,
      routes: [
        GoRouteData.$route(
          path: '/login',
          factory: $LoginRouteExtension._fromState,
        ),
        StatefulShellRouteData.$route(
          factory: $_TabbedRoutesExtension._fromState,
          branches: [
            StatefulShellBranchData.$branch(
              routes: [
                GoRouteData.$route(
                  path: '/activity',
                  factory: $ActivitiesRouteExtension._fromState,
                  routes: [
                    GoRouteData.$route(
                      path: 'new',
                      factory: $NewRouteExtension._fromState,
                    ),
                    GoRouteData.$route(
                      path: ':activityIdString',
                      factory: $ActivityRouteExtension._fromState,
                    ),
                    GoRouteData.$route(
                      path: ':topicIdString',
                      factory: $TopicRouteExtension._fromState,
                    ),
                  ],
                ),
              ],
            ),
            StatefulShellBranchData.$branch(
              routes: [
                GoRouteData.$route(
                  path: '/',
                  factory: $HomeRouteExtension._fromState,
                ),
              ],
            ),
            StatefulShellBranchData.$branch(
              routes: [
                GoRouteData.$route(
                  path: '/settings',
                  factory: $SettingsRouteExtension._fromState,
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

extension $_TabbedRoutesExtension on _TabbedRoutes {
  static _TabbedRoutes _fromState(GoRouterState state) => const _TabbedRoutes();
}

extension $ActivitiesRouteExtension on ActivitiesRoute {
  static ActivitiesRoute _fromState(GoRouterState state) =>
      const ActivitiesRoute();

  String get location => GoRouteData.$location(
        '/activity',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

extension $NewRouteExtension on NewRoute {
  static NewRoute _fromState(GoRouterState state) => NewRoute(
        activityIdString: state.uri.queryParameters['activity-id-string']!,
      );

  String get location => GoRouteData.$location(
        '/activity/new',
        queryParams: {
          'activity-id-string': activityIdString,
        },
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

extension $ActivityRouteExtension on ActivityRoute {
  static ActivityRoute _fromState(GoRouterState state) => ActivityRoute(
        activityIdString: state.pathParameters['activityIdString']!,
      );

  String get location => GoRouteData.$location(
        '/activity/${Uri.encodeComponent(activityIdString)}',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

extension $TopicRouteExtension on TopicRoute {
  static TopicRoute _fromState(GoRouterState state) => TopicRoute(
        topicIdString: state.pathParameters['topicIdString']!,
        activityIdString: state.uri.queryParameters['activity-id-string']!,
      );

  String get location => GoRouteData.$location(
        '/activity/${Uri.encodeComponent(topicIdString)}',
        queryParams: {
          'activity-id-string': activityIdString,
        },
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

extension $HomeRouteExtension on HomeRoute {
  static HomeRoute _fromState(GoRouterState state) => HomeRoute(
        d: state.uri.queryParameters['d'],
      );

  String get location => GoRouteData.$location(
        '/',
        queryParams: {
          if (d != null) 'd': d,
        },
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

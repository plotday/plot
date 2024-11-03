// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'router.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [
      $_AdaptiveRoutes,
      $_SingleRoutes,
    ];

RouteBase get $_AdaptiveRoutes => ShellRouteData.$route(
      factory: $_AdaptiveRoutesExtension._fromState,
      routes: [
        GoRouteData.$route(
          path: '/login',
          factory: $LoginRouteExtension._fromState,
        ),
        GoRouteData.$route(
          path: '/settings',
          factory: $SettingsRouteExtension._fromState,
        ),
        ShellRouteData.$route(
          factory: $_TripleRoutesExtension._fromState,
          routes: [
            GoRouteData.$route(
              path: '/',
              factory: $HomeRouteExtension._fromState,
            ),
            GoRouteData.$route(
              path: '/schedule/:eventId',
              factory: $EventRouteExtension._fromState,
            ),
            GoRouteData.$route(
              path: '/activity/:contextIdString',
              factory: $ActivityRouteExtension._fromState,
            ),
            GoRouteData.$route(
              path: '/activity/:contextIdString/edit',
              factory: $ActivityEditRouteExtension._fromState,
            ),
            GoRouteData.$route(
              path: '/activity/:contextIdString/new',
              factory: $ActivityAddRouteExtension._fromState,
            ),
            GoRouteData.$route(
              path: '/activity/:contextIdString/:topicIdString',
              factory: $TopicRouteExtension._fromState,
            ),
          ],
        ),
      ],
    );

extension $_AdaptiveRoutesExtension on _AdaptiveRoutes {
  static _AdaptiveRoutes _fromState(GoRouterState state) =>
      const _AdaptiveRoutes();
}

extension $LoginRouteExtension on LoginRoute {
  static LoginRoute _fromState(GoRouterState state) => LoginRoute();

  String get location => GoRouteData.$location(
        '/login',
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

extension $_TripleRoutesExtension on _TripleRoutes {
  static _TripleRoutes _fromState(GoRouterState state) => const _TripleRoutes();
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

extension $EventRouteExtension on EventRoute {
  static EventRoute _fromState(GoRouterState state) => EventRoute(
        eventId: state.pathParameters['eventId']!,
      );

  String get location => GoRouteData.$location(
        '/schedule/${Uri.encodeComponent(eventId)}',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

extension $ActivityRouteExtension on ActivityRoute {
  static ActivityRoute _fromState(GoRouterState state) => ActivityRoute(
        contextIdString: state.pathParameters['contextIdString']!,
      );

  String get location => GoRouteData.$location(
        '/activity/${Uri.encodeComponent(contextIdString)}',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

extension $ActivityEditRouteExtension on ActivityEditRoute {
  static ActivityEditRoute _fromState(GoRouterState state) => ActivityEditRoute(
        contextIdString: state.pathParameters['contextIdString']!,
      );

  String get location => GoRouteData.$location(
        '/activity/${Uri.encodeComponent(contextIdString)}/edit',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

extension $ActivityAddRouteExtension on ActivityAddRoute {
  static ActivityAddRoute _fromState(GoRouterState state) => ActivityAddRoute(
        contextIdString: state.pathParameters['contextIdString']!,
      );

  String get location => GoRouteData.$location(
        '/activity/${Uri.encodeComponent(contextIdString)}/new',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

extension $TopicRouteExtension on TopicRoute {
  static TopicRoute _fromState(GoRouterState state) => TopicRoute(
        contextIdString: state.pathParameters['contextIdString']!,
        topicIdString: state.pathParameters['topicIdString']!,
      );

  String get location => GoRouteData.$location(
        '/activity/${Uri.encodeComponent(contextIdString)}/${Uri.encodeComponent(topicIdString)}',
      );

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  void replace(BuildContext context) => context.replace(location);
}

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
                  path: '/',
                  factory: $HomeRouteExtension._fromState,
                  routes: [
                    GoRouteData.$route(
                      path: '/schedule/:eventId',
                      factory: $EventRouteExtension._fromState,
                    ),
                  ],
                ),
              ],
            ),
            StatefulShellBranchData.$branch(
              routes: [
                GoRouteData.$route(
                  path: '/activity/:contextIdString',
                  factory: $ActivityRouteExtension._fromState,
                  routes: [
                    GoRouteData.$route(
                      path: 'edit',
                      factory: $ActivityEditRouteExtension._fromState,
                    ),
                    GoRouteData.$route(
                      path: 'new',
                      factory: $ActivityAddRouteExtension._fromState,
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

extension $_TabbedRoutesExtension on _TabbedRoutes {
  static _TabbedRoutes _fromState(GoRouterState state) => const _TabbedRoutes();
}

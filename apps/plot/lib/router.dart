import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:logging/logging.dart';

import 'state/now.dart';
import 'state/user.dart';
import 'state/priority.dart';
import 'page/page.dart';
import 'widget/app_shell.dart';
import 'widget/priorities_shell.dart';
import 'analytics/analytics.dart';

export 'package:auto_route/auto_route.dart';

part 'router.gr.dart';

final Logger _logger = Logger('plot.route');

@AutoRouterConfig(generateForDir: ['lib', 'lib/page'])
class AppRouter extends RootStackRouter {
  AppRouter();

  @override
  RouteType get defaultRouteType => PlatformResolver.current(
    iOSResolver: () => RouteType.cupertino(),
    androidResolver: () => RouteType.material(),
    defaultResolver: () => RouteType.custom(
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
          page: SignInRoute.page,
          path: 'login',
          guards: [SignInGuard()],
        ),
        AutoRoute(
          page: EmailSignInRoute.page,
          path: 'login/email',
          guards: [SignInGuard()],
        ),
        AutoRoute(
          page: PasswordSetupRoute.page,
          path: 'account/password',
          guards: [SignInGuard()],
        ),
        AutoRoute(
          page: InvitationRoute.page,
          path: 'invitation',
          guards: [AuthGuard()],
        ),
        AutoRoute(
          page: EmptyShellRoute("Now"),
          path: '',
          guards: [
            AuthGuard(),
            AutoRouteGuardCallback((resolver, router) async {
              if (resolver.context.read<NowBloc>().loading) {
                return;
              }
              final priorityId = resolver.context
                  .read<NowBloc>()
                  .loadedState
                  .priority
                  .id;
              resolver.redirectUntil(
                PriorityRoute(priorityIdString: priorityId.toShortString()),
              );
            }),
          ],
        ),
        AutoRoute(
          page: PrioritiesShellRoute.page,
          guards: [AuthGuard()],
          path: '',
          children: [
            AutoRoute(
              page: EmptyShellRoute("PriorityShell"),
              path: '',
              children: [
                AutoRoute(
                  page: PriorityRoute.page,
                  path: ':priorityId',
                  children: [
                    // This route redirects to NewActivityRoute when the middle panel is
                    // already showing PriorityPage.
                    AutoRoute(page: PriorityOnlyRoute.page, path: ''),
                    AutoRoute(
                      page: NewActivityRoute.page,
                      guards: [
                        AutoRouteGuardCallback((resolver, router) async {
                          final priorityBloc = resolver.context
                              .read<PriorityBloc>();
                          priorityBloc.setActivity(null);
                          // Reset draft to ensure a fresh activity each time
                          priorityBloc.resetDraft();
                          resolver.next();
                        }),
                      ],
                      path: 'new',
                    ),
                    AutoRoute(page: ActivityRoute.page, path: ':activityId'),
                  ],
                ),
              ],
            ),
            AutoRoute(page: PrioritiesRoute.page, path: 'priorities'),
          ],
        ),
      ],
    ),
  ];

  @override
  RouterConfig<UrlState> config({
    DeepLinkTransformer? deepLinkTransformer,
    DeepLinkBuilder? deepLinkBuilder,
    String? navRestorationScopeId,
    WidgetBuilder? placeholder,
    NavigatorObserversBuilder navigatorObservers =
        AutoRouterDelegate.defaultNavigatorObserversBuilder,
    bool includePrefixMatches = !kIsWeb,
    bool Function(String? location)? neglectWhen,
    bool rebuildStackOnDeepLink = false,
    Listenable? reevaluateListenable,
    Clip clipBehavior = Clip.hardEdge,
  }) {
    return super.config(
      deepLinkTransformer: deepLinkTransformer,
      deepLinkBuilder: deepLinkBuilder,
      navRestorationScopeId: navRestorationScopeId,
      placeholder: placeholder,
      navigatorObservers: () => [
        RouteLogger(),
        AutoRouteObserver(),
        ...navigatorObservers(),
      ],
      includePrefixMatches: includePrefixMatches,
      neglectWhen: neglectWhen,
      rebuildStackOnDeepLink: rebuildStackOnDeepLink,
      reevaluateListenable: reevaluateListenable,
      clipBehavior: clipBehavior,
    );
  }
}

extension FocusedRouterExtension on BuildContext {
  StackRouter get focusedRouter {
    var focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext?.router ?? router;
  }
}

class AuthGuard extends AutoRouteGuard {
  AuthGuard();

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) {
    final userState = resolver.context.read<UserBloc>().state;
    _logger.fine(
      'AuthGuard checking user state: $userState, ${resolver.route.name}',
    );

    switch (userState) {
      case UserReady():
        // User is authenticated and active, proceed with navigation
        resolver.next();
        break;
      case UserPasswordRequired():
        _logger.info('AuthGuard: Redirecting to PasswordSetupRoute with callback');
        resolver.redirectUntil(
          PasswordSetupRoute(
            onPasswordSet: () {
              _logger.info('AuthGuard: onPasswordSet callback called, calling resolver.next()');
              resolver.next();
            },
          ),
        );
      case UserWaitlisted():
        if (resolver.route.name == InvitationRoute.page.name) {
          // Already heading to InvitationRoute, just proceed
          resolver.next();
        } else {
          _logger.info('AuthGuard: Redirecting to InvitationRoute with callback');
          resolver.redirectUntil(
            InvitationRoute(
              onInvited: () {
                _logger.info('AuthGuard: onInvited callback called, calling resolver.next()');
                resolver.next();
              },
            ),
          );
        }
      case UserSignedOut():
        _logger.info('AuthGuard: Redirecting to SignInRoute with callback');
        resolver.redirectUntil(
          SignInRoute(
            onSignIn: () {
              _logger.info('AuthGuard: onSignIn callback called, calling resolver.next()');
              resolver.next();
            },
          ),
        );
      case UserLoading():
        break;
    }
  }
}

class SignInGuard extends AutoRouteGuard {
  SignInGuard();

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) {
    final userState = resolver.context.read<UserBloc>().state;
    _logger.info(
      'SignInGuard.onNavigation called - userState: $userState, route: ${resolver.route.name}, path: ${resolver.route.path}',
    );

    switch (userState) {
      case UserReady():
        // User is authenticated, redirect away from sign-in page to root
        _logger.info('SignInGuard: User is UserReady, redirecting to /');
        router.navigatePath('/');
        break;
      case UserPasswordRequired():
      case UserWaitlisted():
      case UserSignedOut():
      case UserLoading():
        // User needs to sign in, allow sign-in page to show
        _logger.info(
          'SignInGuard: User not ready ($userState), allowing sign-in page',
        );
        resolver.next();
        break;
    }
  }
}

class RouteLogger extends AutoRouterObserver {
  String? _lastLoggedRoute;
  DateTime? _lastNavigationTime;

  void _log(
    Route<dynamic> route,
    String navigationType,
    Route<dynamic>? previousRoute,
  ) {
    if (route.settings.name != null) {
      final routeInfo =
          '${route.settings.name}${route.settings.arguments == null ? '' : ' (${route.settings.arguments})'}';

      // Only log and track if different from last logged route to avoid duplicates
      if (routeInfo != _lastLoggedRoute) {
        _logger.info('Navigated to $routeInfo');

        // Calculate time on previous screen
        int? timeOnPreviousScreenMs;
        if (_lastNavigationTime != null) {
          timeOnPreviousScreenMs = DateTime.now()
              .difference(_lastNavigationTime!)
              .inMilliseconds;
        }

        // Extract screen name from route (normalize by removing "Route" suffix)
        final screenName = _normalizeScreenName(route.settings.name!);

        // Extract previous screen name
        String? previousScreenName;
        if (previousRoute?.settings.name != null) {
          previousScreenName = _normalizeScreenName(
            previousRoute!.settings.name!,
          );
        }

        // Track navigation to PostHog
        Analytics.instance.trackNavigation(
          screenName,
          buildNavigationProperties(
            screenName: screenName,
            routeParams: route.settings.arguments?.toString(),
            previousScreen: previousScreenName,
            navigationType: navigationType,
            timeOnPreviousScreenMs: timeOnPreviousScreenMs,
          ),
        );

        // Track slow navigation as performance issue
        const navigationThresholdMs = 1000;
        if (timeOnPreviousScreenMs != null &&
            timeOnPreviousScreenMs > navigationThresholdMs) {
          Analytics.instance.trackPerformance(
            object: EventObject.navigation,
            durationMs: timeOnPreviousScreenMs,
            thresholdMs: navigationThresholdMs,
            operationType: 'navigation_to_$screenName',
          );
        }

        _lastLoggedRoute = routeInfo;
        _lastNavigationTime = DateTime.now();
      }
    }
  }

  /// Normalize route names to screen names
  /// Examples:
  /// - PriorityRoute -> priority_detail
  /// - ActivityRoute -> activity_detail
  /// - NewActivityRoute -> new_activity
  /// - PrioritiesRoute -> priorities_list
  String _normalizeScreenName(String routeName) {
    // Remove "Route" suffix
    String name = routeName.replaceAll('Route', '');

    // Convert PascalCase to snake_case
    String snakeCase = name.replaceAllMapped(
      RegExp(r'([A-Z])'),
      (match) => '_${match.group(0)!.toLowerCase()}',
    );

    // Remove leading underscore
    if (snakeCase.startsWith('_')) {
      snakeCase = snakeCase.substring(1);
    }

    // Map common patterns
    if (snakeCase == 'priority') {
      return 'priority_detail';
    } else if (snakeCase == 'activity') {
      return 'activity_detail';
    } else if (snakeCase == 'priorities') {
      return 'priorities_list';
    } else if (snakeCase == 'sign_in') {
      return 'sign_in';
    } else if (snakeCase == 'email_sign_in') {
      return 'email_sign_in';
    } else if (snakeCase == 'password_setup') {
      return 'password_setup';
    } else if (snakeCase == 'invitation') {
      return 'invitation';
    } else if (snakeCase == 'new_activity') {
      return 'new_activity';
    }

    return snakeCase;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _log(route, NavigationType.push, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // When popping, the previousRoute is what we're navigating to
    if (previousRoute != null) {
      _log(previousRoute, NavigationType.pop, route);
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    _log(newRoute, NavigationType.replace, oldRoute);
  }
}

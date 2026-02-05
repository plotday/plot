import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:logging/logging.dart';

import 'auto_sign_in.dart';
import 'page/invite.dart';
import 'state/now.dart';
import 'state/user.dart';
import 'state/priority.dart';
import 'state/local_preferences.dart';
import 'page/page.dart';
import 'widget/app_shell.dart';
import 'widget/priorities_shell.dart';
import 'analytics/tracker.dart';

export 'package:auto_route/auto_route.dart';

part 'router.gr.dart';

final Logger _logger = Logger('plot.route');

@AutoRouterConfig(generateForDir: ['lib', 'lib/page'])
class AppRouter extends RootStackRouter {
  AppRouter();

  @override
  RouteType get defaultRouteType => PlatformResolver.current(
    // Mobile platforms: native transitions
    iOSResolver: () => RouteType.cupertino(),
    androidResolver: () => RouteType.material(),
    // Desktop platforms: immediate transitions (no animation)
    macOSResolver: () => RouteType.custom(
      duration: Duration.zero,
      reverseDuration: Duration.zero,
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          child,
    ),
    windowsResolver: () => RouteType.custom(
      duration: Duration.zero,
      reverseDuration: Duration.zero,
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          child,
    ),
    linuxResolver: () => RouteType.custom(
      duration: Duration.zero,
      reverseDuration: Duration.zero,
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          child,
    ),
    // Web fallback: immediate transitions
    defaultResolver: () => RouteType.custom(
      duration: Duration.zero,
      reverseDuration: Duration.zero,
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          child,
    ),
  );

  @override
  List<AutoRoute> get routes => <AutoRoute>[
    AutoRoute(
      page: AppShellRoute.page,
      path: '/',
      children: [
        AutoRoute(page: PlatformPickerRoute.page, path: 'start'),
        AutoRoute(
          page: SignInRoute.page,
          path: 'login',
          guards: [PlatformPickerGuard(), AuthGuard()],
        ),
        AutoRoute(
          page: EmailSignInRoute.page,
          path: 'login/email',
          guards: [PlatformPickerGuard(), AuthGuard()],
        ),
        AutoRoute(
          page: PasswordSetupRoute.page,
          path: 'account/password',
          guards: [PlatformPickerGuard(), AuthGuard()],
        ),
        AutoRoute(
          page: InviteRoute.page,
          path: 'invite/:token',
          guards: [PlatformPickerGuard(), AuthGuard()],
        ),
        AutoRoute(
          page: EmptyShellRoute("Now"),
          path: '',
          guards: [
            PlatformPickerGuard(),
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
              router.replaceAll([
                PriorityRoute(priorityIdString: priorityId.toShortString()),
              ]);
            }),
          ],
        ),
        AutoRoute(
          page: PrioritiesShellRoute.page,
          guards: [PlatformPickerGuard(), AuthGuard()],
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

/// Guard that ensures web users see the platform picker on first visit
class PlatformPickerGuard extends AutoRouteGuard {
  PlatformPickerGuard();

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) async {
    // Only check on web
    if (!kIsWeb) {
      resolver.next();
      return;
    }

    // Don't redirect if already on platform picker
    if (resolver.route.name == PlatformPickerRoute.page.name) {
      resolver.next();
      return;
    }

    // Check if user has selected web platform
    final localPreferencesBloc = resolver.context.read<LocalPreferencesBloc>();
    final hasSelectedWeb = await localPreferencesBloc
        .getHasSelectedWebPlatform();

    if (!hasSelectedWeb) {
      // User hasn't selected web yet, redirect to platform picker
      _logger.info('PlatformPickerGuard: Redirecting to PlatformPickerRoute');
      resolver.redirectUntil(PlatformPickerRoute());
    } else {
      // User has selected web, proceed with navigation
      resolver.next();
    }
  }
}

class AuthGuard extends AutoRouteGuard {
  AuthGuard();

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) async {
    final userState = resolver.context.read<UserBloc>().state;
    _logger.fine(
      'AuthGuard checking user state: $userState, ${resolver.route.name}',
    );

    switch (userState) {
      case UserReady():
        if ([
          SignInRoute.page.name,
          EmailSignInRoute.page.name,
          PasswordSetupRoute.page.name,
        ].contains(resolver.route.name)) {
          _logger.info('AuthGuard: Redirecting to Now');
          router.replaceAll([EmptyShellRoute("Now")()]);
        } else {
          // User is authenticated and active, proceed with navigation
          // (includes InviteRoute for token redemption)
          resolver.next();
        }
        break;
      case UserPasswordRequired():
        if (resolver.route.name == PasswordSetupRoute.page.name ||
            resolver.route.name == InviteRoute.page.name) {
          resolver.next();
        } else {
          _logger.info('AuthGuard: Redirecting to PasswordSetupRoute');
          resolver.redirectUntil(PasswordSetupRoute());
        }
        break;
      case UserSignedOut():
        if (resolver.route.name == SignInRoute.page.name ||
            resolver.route.name == EmailSignInRoute.page.name ||
            resolver.route.name == InviteRoute.page.name) {
          resolver.next();
        } else {
          // If --user was provided without password, redirect to email sign-in
          if (AutoSignIn.shouldNavigateToSignIn) {
            _logger.info(
              'AuthGuard: Redirecting to EmailSignInRoute with email: ${AutoSignIn.targetUser}',
            );
            resolver.redirectUntil(
              EmailSignInRoute(email: AutoSignIn.targetUser),
            );
          } else {
            _logger.info('AuthGuard: Redirecting to SignInRoute');
            resolver.redirectUntil(SignInRoute());
          }
        }
        break;
      case UserLoading():
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
        Tracker.trackNavigation(
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
          Tracker.trackPerformance(
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
  /// - PriorityRoute -> Priority
  /// - NewActivityRoute -> New Activity
  String _normalizeScreenName(String routeName) {
    return routeName
        // Remove "Route" suffix
        .replaceAll('Route', '')
        // Add spaces before uppercase letters
        .replaceAllMapped(
          RegExp(r'(?<=[a-z])([A-Z])'),
          (match) => ' ${match.group(0)!}',
        );
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

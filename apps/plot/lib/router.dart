import 'package:flutter/widgets.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:logging/logging.dart';

import 'auto_sign_in.dart';
import 'state/user.dart';
import 'state/priority.dart';
import 'page/page.dart';
import 'util/url_override.dart';
import 'widget/app_shell.dart';
import 'widget/priorities_shell.dart';
import 'analytics/tracker.dart';

export 'package:auto_route/auto_route.dart';

part 'router.gr.dart';

final Logger _logger = Logger('plot.route');

/// Wires the browser URL override so a thread page displays as the shareable
/// `/t/:threadId` form even though the internal router stack still carries
/// the nested `/p/:priorityId/:threadId` shape (which is what keeps the
/// priority shell stable across thread/new-thread transitions and makes
/// back-navigation return to the priority). Must be invoked once on the
/// configured root router.
void installThreadUrlOverride(StackRouter router) {
  final history = router.navigationHistory;
  String? previousThreadId;
  void sync() {
    final threadId = _activeThreadId(history.urlState.segments);
    if (threadId != null) {
      // Push a new browser history frame when first entering a thread from a
      // non-thread URL so the browser back button returns the user to that
      // previous URL. When hopping between threads, replace in-place so the
      // history doesn't grow a frame per thread.
      setBrowserUrl('/t/$threadId', push: previousThreadId == null);
    }
    previousThreadId = threadId;
  }

  history.addListener(sync);
  // Handle the initial URL so a cold-load of `/p/:pid/:tid` rewrites too.
  sync();
}

/// Matches nested thread URLs (`/p/:priorityId/:threadId` and not the
/// reserved `/p/:priorityId/new`). Used to suppress auto_route's emission so
/// the browser URL stays pinned to the canonical `/t/:threadId` form we set
/// ourselves in [installThreadUrlOverride].
final _nestedThreadUrlPattern = RegExp(r'^/p/[^/]+/(?!new(?:$|/))[^/]+/?$');

bool _neglectNestedThreadPath(String? location) {
  if (location == null) return false;
  final path = Uri.parse(location).path;
  return _nestedThreadUrlPattern.hasMatch(path);
}

/// Returns the threadId short-string if a [ThreadRoute] is the deepest
/// segment in [segments], otherwise null.
String? _activeThreadId(List<RouteMatch<dynamic>> segments) {
  if (segments.isEmpty) return null;
  RouteMatch<dynamic> current = segments.last;
  while (current.hasChildren) {
    current = current.children!.last;
  }
  if (current.name != ThreadRoute.name) return null;
  return current.params.getString('threadId');
}

/// Flips to `true` after the first frame of the app has rendered. The
/// thread-route customRouteBuilder consults this to suppress the iOS
/// slide on cold-start navigations (e.g. iPad multi-panel auto-forward
/// from PriorityOnlyRoute → NewThreadRoute, deep-linked /t/:id) where
/// there's no real source page to slide from.
bool _appFirstFrameRendered = false;

@AutoRouterConfig(generateForDir: ['lib', 'lib/page'])
class AppRouter extends RootStackRouter {
  AppRouter({this.userBloc}) {
    if (!_appFirstFrameRendered) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _appFirstFrameRendered = true;
      });
    }
  }

  /// The app's stable [UserBloc] instance, handed to every [AuthGuard] so the
  /// guard can read auth state from it directly instead of resolving it from
  /// the navigation context. During sign-out the router re-evaluates guards,
  /// and the `resolver.context` it passes can already be deactivated — reading
  /// a provider off it then throws "Looking up a deactivated widget's ancestor
  /// is unsafe". The bloc reference is stable, so it sidesteps that lookup.
  final UserBloc? userBloc;

  // Default to zero-duration on every platform. Shell routes
  // (AppShell, PrioritiesShellRoute, AgendaShell, ActivityShell, the
  // priorities/agenda/sign-in pages) inherit this and mount instantly,
  // which keeps the bottom nav and chrome from sliding in on cold
  // start. Routes that *should* slide (ThreadRoute, NewThreadRoute on
  // iOS) opt in explicitly via `type:` below.
  @override
  RouteType get defaultRouteType => RouteType.custom(
    duration: Duration.zero,
    reverseDuration: Duration.zero,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        child,
  );

  /// Route type for ThreadRoute / NewThreadRoute. Picks the
  /// platform-native push transition for mobile and skips animation
  /// everywhere else:
  ///   - iOS    → CupertinoPageRoute (slide + swipe-to-pop)
  ///   - Android → MaterialPageRoute (Material zoom/fade)
  ///   - macOS, Windows, Linux, web → no animation
  /// Cold-start navigations (`_appFirstFrameRendered == false`) always
  /// skip the transition — there's no source page to animate from when
  /// the route is mounted as part of initial route resolution (e.g.
  /// iPad multi-panel auto-forward, deep-linked /t/:id).
  final RouteType _threadRouteType = RouteType.custom(
    customRouteBuilder: <T>(context, child, page) {
      if (!kIsWeb && _appFirstFrameRendered) {
        switch (defaultTargetPlatform) {
          case TargetPlatform.iOS:
            return CupertinoPageRoute<T>(
              settings: page,
              builder: (_) => child,
            );
          case TargetPlatform.android:
            return MaterialPageRoute<T>(
              settings: page,
              builder: (_) => child,
            );
          case TargetPlatform.macOS:
          case TargetPlatform.windows:
          case TargetPlatform.linux:
          case TargetPlatform.fuchsia:
            break;
        }
      }
      return PageRouteBuilder<T>(
        settings: page,
        pageBuilder: (_, _, _) => child,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      );
    },
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
          guards: [AuthGuard(userBloc)],
        ),
        AutoRoute(
          page: EmailSignInRoute.page,
          path: 'login/email',
          guards: [AuthGuard(userBloc)],
        ),
        AutoRoute(
          page: PasswordSetupRoute.page,
          path: 'account/password',
        ),
        AutoRoute(
          page: InviteRoute.page,
          path: 'invite/:token',
          guards: [AuthGuard(userBloc)],
        ),
        AutoRoute(
          page: RootRoute.page,
          path: '',
          guards: [AuthGuard(userBloc)],
        ),
        AutoRoute(
          page: PrioritiesShellRoute.page,
          guards: [AuthGuard(userBloc)],
          path: '',
          children: [
            // Tab 0: Priorities list
            AutoRoute(page: PrioritiesRoute.page, path: 'priorities'),
            // Tab 1: Agenda — its own stack so tab switches preserve state
            // independently from the Activity tab.
            AutoRoute(
              page: EmptyShellRoute("AgendaShell"),
              path: 'agenda',
              children: [
                AutoRoute(
                  page: AgendaRoute.page,
                  path: '',
                  guards: [AuthGuard(userBloc)],
                ),
              ],
            ),
            // Tab 2: Activity (per-priority feeds, threads, new-thread,
            // and standalone thread links). Default catch-all so deep
            // links to /p/:id and /t/:id resolve here.
            AutoRoute(
              page: EmptyShellRoute("ActivityShell"),
              path: '',
              children: [
                // Canonical priority URL: /p/:priorityId
                AutoRoute(
                  page: PriorityRoute.page,
                  path: 'p/:priorityId',
                  children: [
                    // This route redirects to NewThreadRoute when the middle panel is
                    // already showing PriorityPage.
                    AutoRoute(page: PriorityOnlyRoute.page, path: ''),
                    // ThreadRoute and NewThreadRoute opt in to native
                    // push transitions on mobile (cupertino on iOS,
                    // material on Android). Desktop and web mount
                    // instantly with no animation, as do iOS/Android
                    // cold-start navigations. See [_threadRouteType].
                    AutoRoute(
                      page: NewThreadRoute.page,
                      guards: [
                        AutoRouteGuardCallback((resolver, router) async {
                          final priorityBloc = resolver.context
                              .read<PriorityBloc>();
                          priorityBloc.setThread(null);
                          resolver.next();
                        }),
                      ],
                      path: 'new',
                      type: _threadRouteType,
                    ),
                    AutoRoute(
                      page: ThreadRoute.page,
                      path: ':threadId',
                      type: _threadRouteType,
                      // Make the page key path-based so ThreadRoute(A) and
                      // ThreadRoute(B) get distinct ValueKeys. Without this,
                      // both share `ValueKey("ThreadRoute")`, so when
                      // innerRouter.replace swaps A→B Flutter's Navigator
                      // sees `canUpdate=true` and updates the existing route
                      // in place — the ThreadBlocProvider's threadId stays
                      // bound to A and the right panel never changes.
                      usesPathAsKey: true,
                    ),
                  ],
                ),
                // Canonical standalone thread URL: /t/:threadId — resolves
                // the thread's priority and replaces the stack with the
                // nested PriorityRoute + ThreadRoute form.
                AutoRoute(
                  page: ThreadLookupRoute.page,
                  path: 't/:threadId',
                ),
                // Internal landing for multi-thread notification taps.
                // Prefetches missing thread rows then forwards to the LCA
                // priority's activity feed. Not part of the public URL
                // surface — only reached via the notification flow.
                AutoRoute(
                  page: NotificationLandingRoute.page,
                  path: 'n/:priorityId/:threadIds',
                ),
              ],
            ),
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
      deepLinkTransformer: deepLinkTransformer ?? _legacyDeepLinkTransformer,
      deepLinkBuilder: deepLinkBuilder,
      navRestorationScopeId: navRestorationScopeId,
      // Without a placeholder, auto_route's navigator falls back to a
      // `Container(color: Theme.of(context).scaffoldBackgroundColor)` while
      // the initial route is resolving. On macOS we use MacosApp.router (no
      // MaterialApp ancestor), so `Theme.of` returns the default light
      // Material theme — producing a one-frame white flash between
      // LoadingPage and the main panels in dark mode.
      placeholder: placeholder ?? (_) => const LoadingPage(),
      navigatorObservers: () => [
        RouteLogger(),
        AutoRouteObserver(),
        ...navigatorObservers(),
      ],
      includePrefixMatches: includePrefixMatches,
      // Suppress auto_route's own URL emission for nested thread paths so our
      // listener (in [installThreadUrlOverride]) can publish the canonical
      // shareable `/t/:threadId` URL without being clobbered a frame later.
      neglectWhen: neglectWhen ?? _neglectNestedThreadPath,
      rebuildStackOnDeepLink: rebuildStackOnDeepLink,
      reevaluateListenable: reevaluateListenable,
      clipBehavior: clipBehavior,
    );
  }
}

/// Rewrites pre-stage-8 URLs into the new canonical forms:
///
///   /:priorityId              → /p/:priorityId
///   /:priorityId/new          → /p/:priorityId/new
///   /:priorityId/:threadId    → /t/:threadId
///
/// Only threads are deep-linked between users, so the priority segment
/// is dropped for legacy thread URLs — the new standalone thread route
/// resolves per-user filing client-side.
Future<Uri> _legacyDeepLinkTransformer(Uri uri) async {
  final segments = uri.pathSegments;
  if (segments.isEmpty) return uri;
  final first = segments.first;
  // Pass through already-canonical and non-entity paths untouched.
  const reserved = {
    'p',
    't',
    'login',
    'priorities',
    'invite',
    'account',
  };
  if (reserved.contains(first)) return uri;

  if (segments.length == 1) {
    return uri.replace(pathSegments: ['p', segments[0]]);
  }
  if (segments.length >= 2) {
    if (segments[1] == 'new') {
      return uri.replace(pathSegments: ['p', segments[0], 'new']);
    }
    // Legacy /priority/thread → canonical /t/thread (priority is
    // resolved per-user via ThreadLookupRoute).
    return uri.replace(pathSegments: ['t', segments[1]]);
  }
  return uri;
}

extension FocusedRouterExtension on BuildContext {
  StackRouter get focusedRouter {
    var focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext?.router ?? router;
  }
}

class AuthGuard extends AutoRouteGuard {
  AuthGuard([this._userBloc]);

  /// Stable bloc reference, preferred over a context read so guard
  /// re-evaluation during sign-out doesn't touch a deactivated context.
  final UserBloc? _userBloc;

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) async {
    final userState =
        (_userBloc ?? resolver.context.read<UserBloc>()).state;
    _logger.fine(
      'AuthGuard checking user state: $userState, ${resolver.route.name}',
    );

    switch (userState) {
      case UserReady():
        if ([
          SignInRoute.page.name,
          EmailSignInRoute.page.name,
        ].contains(resolver.route.name)) {
          _logger.info('AuthGuard: Redirecting to RootRoute');
          router.replaceAll([const RootRoute()]);
        } else {
          // User is authenticated and active, proceed with navigation
          // (includes InviteRoute for token redemption)
          resolver.next();
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
  /// - NewThreadRoute -> New Thread
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

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/screenshot/scenes.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/cli_args.dart';
import 'package:plot/command/command.dart';
import 'package:plot/command/page_link.dart';
import 'package:plot/notifications/notification_service.dart';
import 'package:plot/page/invite.dart';
import 'package:plot/share_intent.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/compose_targets.dart';
import 'package:plot/state/user.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/onboarding.dart';
import 'package:plot/state/post_auth_navigation_gate.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/settings.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/state/user_scoped_preferences.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/router.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/root_menu_bar.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/main.dart' show navigatorKey, setNavigatorKey;
import 'package:plot/util/splash.dart';
import 'package:plot/util/window_title.dart';
import 'package:plot/widget_bridge/widget_bridge.dart';
import 'logging.dart';

class RootProvider extends StatefulWidget {
  const RootProvider({required this.builder, super.key});

  @override
  RootProviderState createState() => RootProviderState();

  final Widget Function(RouterConfig<UrlState> routerConfig) builder;
}

class RootProviderState extends State<RootProvider> {
  final UserBloc userBloc = UserBloc();
  final NowBloc nowBloc = NowBloc();
  final PrioritiesBloc prioritiesBloc = PrioritiesBloc();
  late final AppRouter router;
  late final RouterConfig<UrlState> routerConfig;
  late final WidgetBridge widgetBridge = WidgetBridge(
    userBloc: userBloc,
    nowBloc: nowBloc,
  );

  void Function()? _nowBlocListener;
  StreamSubscription<Priority>? _contextPriorityListener;
  StreamSubscription<void>? _reAuthSubscription;
  bool _hasNavigatedToCliUrl = false;
  bool _routerInitialized = false;

  /// Gates the post-auth jump to the default priority so it fires only on a
  /// genuine re-sign-in — never on cold start / web refresh, where it would
  /// clobber the router's already-resolved deep link. See
  /// [PostAuthNavigationGate].
  final PostAuthNavigationGate _postAuthNav = PostAuthNavigationGate();
  NotificationTapTarget? _pendingNotificationTarget;

  @override
  void initState() {
    Bloc.observer = BlocLogger();

    // Create router and expose its navigator key globally for deep link handling
    router = AppRouter(userBloc: userBloc);
    setNavigatorKey(router.navigatorKey);

    routerConfig = router.config(
      reevaluateListenable: ReevaluateListenable.stream(userBloc.stream),
    );
    installThreadUrlOverride(router);
    widgetBridge.start();
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      removeSplash();
    });
  }

  @override
  void dispose() {
    Role.cache.removeListener(_applyWindowTitle);
    _nowBlocListener?.call();
    _contextPriorityListener?.cancel();
    _reAuthSubscription?.cancel();
    PendingShare.onReady = null;
    unawaited(widgetBridge.stop());
    super.dispose();
  }

  void _setupNowBlocListener(ThemeBloc themeBloc) {
    _nowBlocListener?.call();
    // Refresh the window/tab title once the role cache warms (so the
    // `[Role] ›` prefix appears even when roles finish syncing after the
    // first navigation) and whenever roles are added/renamed/removed.
    Role.cache.removeListener(_applyWindowTitle);
    Role.cache.addListener(_applyWindowTitle);
    _nowBlocListener = nowBloc.stream.listen((state) {
      if (state is NowLoaded && state.context != null) {
        themeBloc.setPriorityColor(state.context!.displayColor);
        setWindowTitle(windowTitleForFocus(state.context));

        // Set up Priority watcher to detect color changes
        _contextPriorityListener?.cancel();
        _contextPriorityListener = Priority.watchOne(state.context!.id).listen((
          priority,
        ) {
          themeBloc.setPriorityColor(priority.displayColor);
          // Reflect focus renames (and re-filings into another role) in the
          // title as they happen.
          setWindowTitle(windowTitleForFocus(priority));
        });
      } else {
        // No context, cancel Priority listener
        _contextPriorityListener?.cancel();
        _contextPriorityListener = null;
        setWindowTitle(windowTitleForFocus(null));
      }
    }).cancel;
  }

  /// Recomputes the window/tab title from the current focus. Used as the
  /// [Role.cache] listener so the title gains its `[Role] ›` prefix the moment
  /// roles become available.
  void _applyWindowTitle() {
    final state = nowBloc.state;
    final context = state is NowLoaded ? state.context : null;
    setWindowTitle(windowTitleForFocus(context));
  }

  void _teardownNowBlocListener() {
    Role.cache.removeListener(_applyWindowTitle);
    _nowBlocListener?.call();
    _nowBlocListener = null;
    _contextPriorityListener?.cancel();
    _contextPriorityListener = null;
  }

  void _setupReAuthListener(BuildContext listenerContext) {
    _reAuthSubscription?.cancel();
    _reAuthSubscription = Base.needsReAuth.listen((_) {
      if (listenerContext.mounted) {
        listenerContext.showToast(
          title: 'Session expired',
          message: 'Signing out...',
          isError: true,
          duration: const Duration(seconds: 3),
        );
      }
    });
  }

  void _navigateToUrl(BuildContext navigateContext, String url) {
    log.info('Navigating to CLI URL: $url');
    // Use the OpenPageLink command for navigation
    navigateContext.run(OpenPageLink(url));
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => userBloc),
        BlocProvider(create: (_) => nowBloc),
        BlocProvider(create: (_) => prioritiesBloc),
      ],
      child: BlocListener<UserBloc, UserState>(
        listener: (context, state) async {
          final themeBloc = context.read<ThemeBloc>();

          switch (state) {
            case UserReady _:
              // Decide BEFORE the async setup whether this ready is a
              // re-sign-in (came back from signed-out) so a concurrent
              // sign-out during setup can't change the answer.
              final navigateToDefault =
                  _postAuthNav.shouldNavigateToDefaultOnReady();
              try {
                final onboardingBloc = context.read<OnboardingBloc>();
                // Each .start() awaits its first Drift stream emission and they
                // have no inter-dependencies — running them in parallel lets
                // cold-start gate on the slowest single emission instead of
                // the sum of all three.
                await Future.wait([
                  prioritiesBloc.start(),
                  TwistInstance.start(),
                  nowBloc.start(),
                ]);
                if (kDebugMode && CliArgs.scene != null) {
                  unawaited(Scenes.run(CliArgs.scene!));
                }
                _setupNowBlocListener(themeBloc);
                unawaited(onboardingBloc.start());
                unawaited(NotificationService.instance.start(userId: state.user.id, userName: state.user.name));
                NotificationService.instance.onNavigate = (target) {
                  if (!_routerInitialized) {
                    // Buffer for replay once router is ready (cold start)
                    _pendingNotificationTarget = target;
                    return;
                  }
                  _navigateToNotificationTarget(target);
                };
                if (context.mounted) _setupReAuthListener(context);

                // On a re-sign-in, re-bind the app-root blocs whose Drift
                // subscriptions were created against the previous user's
                // now-closed Store (these blocs aren't recreated per user).
                // Without this they keep emitting the previous user's settings
                // and compose targets. Pairs with the store-cache clears and
                // preference reset in the UserSignedOut handler.
                if (navigateToDefault && context.mounted) {
                  unawaited(context.read<SettingsBloc>().restart());
                  context.read<ComposeTargetsBloc>().restart();
                }

                // On a re-sign-in (user signed out and back in while the app
                // was running) jump to the current-priority cascade. NOT on
                // cold start / web refresh: there the router has already
                // resolved the real browser URL (a deep link to a focus or
                // thread) and clobbering it bounces the user to their Inbox.
                // See [PostAuthNavigationGate].
                if (navigateToDefault && context.mounted) {
                  // Use the current-priority cascade (active event/block,
                  // running session, or last-open focus, else Inbox) so a
                  // re-sign-in lands where a cold start would. Cold start /
                  // deep-link refresh is still gated out by
                  // PostAuthNavigationGate above.
                  final priorityId = nowBloc.loadedState.priority.id;
                  router.replaceAll([
                    PriorityRoute(
                      priorityIdString: priorityId.toShortString(),
                    ),
                  ]);
                }

                // Auto-redeem pending invite (user just signed in/up via invite flow)
                if (context.mounted && PendingInvite.token != null) {
                  try {
                    final result = await api.post<Map<String, dynamic>>(
                      '/invitation/redeem',
                      body: {'token': PendingInvite.token},
                    );
                    final error = result['error'] as String?;
                    if (error != null) {
                      log.warning('Failed to redeem invitation: $error');
                    }
                    PendingInvite.clear();
                  } catch (e) {
                    log.warning('Error redeeming invitation', e);
                    PendingInvite.clear();
                  }
                }
                // Navigate to CLI URL if provided (only once)
                else if (context.mounted &&
                    !_hasNavigatedToCliUrl &&
                    CliArgs.url != null) {
                  _hasNavigatedToCliUrl = true;
                  final url = CliArgs.url!;
                  _navigateToUrl(context, url);
                }
              } catch (error, stackTrace) {
                log.severe('Failed to start app', error, stackTrace);
                await Tracker.captureException(error, stackTrace);
                if (context.mounted) {
                  context.showToast(message: 'Failed to load', isError: true);
                }
                await Base.signOut();
              }
              break;
            case UserSignedOut _:
              // Latch the sign-out so the next UserReady is recognised as a
              // re-sign-in (and navigates to the default priority).
              _postAuthNav.onSignedOut();
              // Drop this user's device-local, user-scoped preferences so a
              // different account signing in on the same device doesn't inherit
              // their focus links, @-mention contacts, or compose connections.
              // Reset the in-memory copy first (this bloc lives at the app root
              // and isn't recreated per user), then clear the persisted keys.
              // Mirrors the in-memory cache clears below. See
              // [clearUserScopedPreferences].
              context.read<LocalPreferencesBloc>().reset();
              await clearUserScopedPreferences();
              await NotificationService.instance.stop();
              _teardownNowBlocListener();
              _reAuthSubscription?.cancel();
              _reAuthSubscription = null;
              prioritiesBloc.stop();
              nowBloc.stop();
              TwistInstance.stopGlobalWatch();
              Actor.clearCache();
              Link.clearCache();
              Priority.clearCache();
              Role.clearCache();
              // The remaining per-user synchronous store caches. Like the four
              // above, they survive sign-out and would otherwise seed the next
              // user's reads from the previous user's data until their own pull
              // lands. (TwistInstance's cache is cleared by stopGlobalWatch.)
              Group.clearCache();
              Topic.clearCache();
              Channel.clearCache();
              // Reset the window/tab title to the bare app name.
              setWindowTitle(windowTitleForFocus(null));
              // Set theme to Catalyst when signed out
              themeBloc.setPriorityColor(ThemeColor(0));
              await router.replaceAll([SignInRoute()]);
              // Wait for widget tree to update and dispose old widgets before removing Store
              await WidgetsBinding.instance.endOfFrame;
              await Store.stop();
              // Clear actorId after all blocs and store are stopped to prevent
              // race conditions with streams accessing actorId during cleanup
              Base.clearActorId();
              break;
            default:
              break;
          }
        },
        child: RootMenuBar(
          child: BlocBuilder<UserBloc, UserState>(
            builder: (context, userState) {
              if (userState is UserLoading) {
                return const LoadingPage();
              }
              return BlocBuilder<NowBloc, NowState>(
                builder: (context, nowState) {
                  // Only gate on NowLoaded when UserReady, because the Now
                  // route guard deadlocks when NowBloc is still loading.
                  // For other states (SignedOut, PasswordRequired), the
                  // AuthGuard redirects before the NowBloc guard runs.
                  // Once built, keep the router in the tree across all
                  // subsequent state changes for widget stability.
                  if (!_routerInitialized &&
                      userState is UserReady &&
                      nowState is NowLoading) {
                    return const LoadingPage();
                  }
                  if (!_routerInitialized) {
                    _routerInitialized = true;
                    // Replay buffered cold-start actions after this build frame
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_pendingNotificationTarget != null) {
                        final target = _pendingNotificationTarget!;
                        _pendingNotificationTarget = null;
                        _navigateToNotificationTarget(target);
                      }

                      // Handle pending share intent (may arrive before or after
                      // router is ready — onReady replays if already buffered,
                      // or fires when the URL arrives later).
                      //
                      // Waits for the navigator to be mounted AND for the
                      // router's initial navigation to settle on a leaf route
                      // (not one of the shell routes: AppShellRoute,
                      // PrioritiesShellRoute, EmptyShellRoute). Pushing while
                      // the initial nav is still resolving loses the race —
                      // auto_route consolidates our pushed PriorityRoute with
                      // the default PriorityRoute the initial nav is about to
                      // land on, and drops our `children: [NewThreadRoute]`.
                      PendingShare.onReady = (url) {
                        String previousPath = '';
                        void attempt(int tries) {
                          final ctx = navigatorKey?.currentContext;
                          final mounted = ctx?.mounted == true;
                          // `router.current.name` only reports the top-level
                          // route (always "AppShellRoute" here) — it never
                          // changes as the inner navigators resolve through
                          // shells to a leaf. `currentPath` walks the full
                          // nested stack and becomes the actual destination
                          // (e.g. "/agenda" or "/p/<id>") once cold-start
                          // navigation lands.
                          final currentPath = mounted ? router.currentPath : '';
                          // Settled = mounted, past the bare "/" entry point,
                          // and stable for two consecutive frames so we don't
                          // race the initial /agenda or /p/<id> redirect.
                          final settled = mounted &&
                              currentPath.isNotEmpty &&
                              currentPath != '/' &&
                              currentPath == previousPath;
                          log.info(
                            'PendingShare.onReady callback attempt #$tries: '
                            'mounted=$mounted, path="$currentPath", '
                            'prev="$previousPath", settled=$settled',
                          );
                          if (settled) {
                            ctx!.run(OpenSharedLink(url));
                          } else if (tries < 30) {
                            previousPath = currentPath;
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => attempt(tries + 1),
                            );
                          } else {
                            log.warning(
                              'PendingShare.onReady: gave up after $tries attempts '
                              '— router never settled (last path="$currentPath")',
                            );
                          }
                        }
                        attempt(1);
                      };
                    });
                  }
                  return widget.builder(routerConfig);
                },
              );
            },
          ),
        ),
      ),
    );
  }

  /// Navigate to a notification's target, but only once the router has settled
  /// on a real leaf route.
  ///
  /// On a cold-start tap the router first resolves its own initial navigation —
  /// the restored last-open focus (and, with OS route restoration, the
  /// previously-open thread) — through several frames of nested-shell
  /// resolution. A `replaceAll` issued before that settles races it: auto_route
  /// can consolidate our route away, leaving the user on whatever the cold start
  /// restored (e.g. the thread they last had open) instead of the notified
  /// thread. This is the same race [PendingShare.onReady] guards against. Wait
  /// for a stable, non-"/" path first so the notification navigation reliably
  /// wins. (On a warm tap the path is already settled, so this runs on the first
  /// frame — no added latency.)
  void _navigateToNotificationTarget(NotificationTapTarget target) {
    String previousPath = '';
    void attempt(int tries) {
      final ctx = navigatorKey?.currentContext;
      final mounted = ctx?.mounted == true;
      final currentPath = mounted ? router.currentPath : '';
      final settled = mounted &&
          currentPath.isNotEmpty &&
          currentPath != '/' &&
          currentPath == previousPath;
      if (settled) {
        _applyNotificationTarget(target);
      } else if (tries < 30) {
        previousPath = currentPath;
        WidgetsBinding.instance.addPostFrameCallback((_) => attempt(tries + 1));
      } else {
        // Unlike PendingShare (which drops on give-up), a dropped notification
        // target leaves the user stranded on the wrong route — the exact bug.
        // Navigate best-effort instead.
        log.warning(
          'Notification nav: router never settled after $tries attempts '
          '(last path="$currentPath") — navigating anyway',
        );
        _applyNotificationTarget(target);
      }
    }

    attempt(1);
  }

  void _applyNotificationTarget(NotificationTapTarget target) {
    // Single new thread → open it directly so the user lands in the
    // thread instead of having to find it in the activity feed.
    // ThreadLookupPage handles "row not local yet" by prefetching the
    // thread by id before resolving, showing a LoadingPage while it does.
    if (target.threadIds.length == 1) {
      try {
        final threadShort = Uuid.fromString(target.threadIds.first)
            .toShortString();
        router.replaceAll([ThreadLookupRoute(threadIdString: threadShort)]);
        return;
      } catch (e) {
        // Bad thread id from a stale/malformed payload — fall through to
        // priority navigation so the tap still does something useful.
        log.warning('Bad thread id in notification target: ${target.threadIds.first}', e);
      }
    }

    final shortId = Uuid.fromString(target.priorityId).toShortString();

    // Multiple new threads → go through NotificationLandingPage so missing
    // thread rows are prefetched (showing a LoadingPage) before the user
    // lands on the activity feed.
    if (target.threadIds.length > 1) {
      // NOTE: PendingActivityFeedView.openUnreadOnly is set in
      // NotificationLandingPage._resolve() immediately before the final
      // replaceAll, AFTER the async prefetch completes, to avoid a stale-flag
      // leak when the user navigates away during the prefetch window.
      router.replaceAll([
        NotificationLandingRoute(
          priorityIdString: shortId,
          threadIdsString: target.threadIds.join(','),
        ),
      ]);
      return;
    }

    // No thread ids on the payload (very old format / fallback) — open the
    // target priority directly.
    // Signal PriorityPage to auto-enable the unread filter on mount.
    PendingActivityFeedView.openUnreadOnly = true;
    router.replaceAll([PriorityRoute(priorityIdString: shortId)]);
  }
}

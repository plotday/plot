import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/cli_args.dart';
import 'package:plot/command/command.dart';
import 'package:plot/command/page_link.dart';
import 'package:plot/notifications/notification_service.dart';
import 'package:plot/page/invite.dart';
import 'package:plot/share_intent.dart';
import 'package:plot/state/user.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/router.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/root_menu_bar.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/main.dart' show setNavigatorKey;
import 'package:plot/util/splash.dart';
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

  void Function()? _nowBlocListener;
  StreamSubscription<Priority>? _contextPriorityListener;
  StreamSubscription<void>? _reAuthSubscription;
  bool _hasNavigatedToCliUrl = false;
  bool _routerInitialized = false;
  String? _pendingNotificationPriorityId;

  @override
  void initState() {
    Bloc.observer = BlocLogger();

    // Create router and expose its navigator key globally for deep link handling
    router = AppRouter();
    setNavigatorKey(router.navigatorKey);

    routerConfig = router.config(
      reevaluateListenable: ReevaluateListenable.stream(userBloc.stream),
    );
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      removeSplash();
    });
  }

  @override
  void dispose() {
    _nowBlocListener?.call();
    _contextPriorityListener?.cancel();
    _reAuthSubscription?.cancel();
    super.dispose();
  }

  void _setupNowBlocListener(ThemeBloc themeBloc) {
    _nowBlocListener?.call();
    _nowBlocListener = nowBloc.stream.listen((state) {
      if (state is NowLoaded && state.context != null) {
        themeBloc.setPriorityColor(state.context!.displayColor);

        // Set up Priority watcher to detect color changes
        _contextPriorityListener?.cancel();
        _contextPriorityListener = Priority.watchOne(state.context!.id).listen((
          priority,
        ) {
          themeBloc.setPriorityColor(priority.displayColor);
        });
      } else {
        // No context, cancel Priority listener
        _contextPriorityListener?.cancel();
        _contextPriorityListener = null;
      }
    }).cancel;
  }

  void _teardownNowBlocListener() {
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
              try {
                await prioritiesBloc.start();
                await PriorityTwist.start();
                await nowBloc.start();
                _setupNowBlocListener(themeBloc);
                unawaited(NotificationService.instance.start(userId: state.user.id, userName: state.user.name));
                NotificationService.instance.onNavigateToPriority = (priorityId) {
                  if (!_routerInitialized) {
                    // Buffer for replay once router is ready (cold start)
                    _pendingNotificationPriorityId = priorityId;
                    return;
                  }
                  _navigateToNotificationPriority(priorityId);
                };
                if (context.mounted) _setupReAuthListener(context);

                // Navigate to main app after re-sign-in. On first startup
                // _routerInitialized is still false (router not yet built),
                // so the router's own initial navigation handles it.
                if (_routerInitialized && context.mounted) {
                  final priorityId = nowBloc.loadedState.defaultPriority.id;
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
                // Open pending shared link (from cold start share intent)
                else if (context.mounted && PendingShare.url != null) {
                  final sharedUrl = PendingShare.url!;
                  PendingShare.url = null;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (context.mounted) {
                      context.run(OpenSharedLink(sharedUrl));
                    }
                  });
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
              await NotificationService.instance.stop();
              _teardownNowBlocListener();
              _reAuthSubscription?.cancel();
              _reAuthSubscription = null;
              prioritiesBloc.stop();
              nowBloc.stop();
              PriorityTwist.stopGlobalWatch();
              Actor.clearCache();
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
                    // Replay buffered notification navigation (cold start)
                    if (_pendingNotificationPriorityId != null) {
                      final id = _pendingNotificationPriorityId!;
                      _pendingNotificationPriorityId = null;
                      // Schedule after this build frame completes
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _navigateToNotificationPriority(id);
                      });
                    }
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

  void _navigateToNotificationPriority(String priorityId) {
    final shortId = Uuid.fromString(priorityId).toShortString();
    router.replaceAll([
      PriorityRoute(priorityIdString: shortId, tab: 'activity'),
    ]);
  }
}

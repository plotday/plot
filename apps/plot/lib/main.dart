import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';
import 'package:super_editor/super_editor.dart' show LogNames;
import 'package:app_links/app_links.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter/services.dart' show MethodChannel;

import 'analytics/tracker.dart';
import 'app.dart';
import 'app_info.dart';
import 'env.dart';
import 'auto_sign_in.dart';
import 'base.dart';
import 'cli_args.dart';
import 'firebase_options.dart';
import 'logging.dart';
import 'notifications/background_handler.dart';
import 'widget/window.dart';
import 'widget/auth_button.dart';
import 'util/time_service.dart' show Time;
import 'util/profile_preferences.dart';
import 'util/instance_lock.dart';
import 'command/page_link.dart';
import 'command/command.dart' show BuildContextCommandExtension;
import 'command/share.dart';
import 'page/invite.dart';
import 'share_intent.dart';

/// iOS-only: reads shared content written by the ShareExtension from the App
/// Group UserDefaults. Workaround for share_handler_ios's case-sensitive
/// scheme check — iOS lowercases URL schemes via Launch Services, so
/// `hasPrefix("ShareMedia-...")` never matches the incoming `sharemedia-...`
/// URL, and app_links intercepts the URL instead.
const _iosShareChannel = MethodChannel('day.plot.app/share_ios');

Future<String?> _readIosSharedContent(Uri uri) async {
  final key = uri.queryParameters['key'] ?? 'ShareKey';
  try {
    return await _iosShareChannel.invokeMethod<String>(
      'readSharedContent',
      {'key': key},
    );
  } catch (e, t) {
    // Catches both PlatformException and MissingPluginException
    // (the latter fires if the native handler isn't registered yet).
    log.warning('readSharedContent failed', e, t);
    return null;
  }
}

/// True if [uri] is a deep link from the iOS ShareExtension. iOS lowercases
/// URL schemes, so we match case-insensitively.
bool _isIosShareDeepLink(Uri uri) {
  return uri.scheme.toLowerCase().startsWith('sharemedia-');
}

// Global instance lock for cleanup
InstanceLock? _instanceLock;

// Getter for instance lock (for cleanup in window.dart)
InstanceLock? get instanceLock => _instanceLock;

// Guard against re-registering Logger listeners on hot restart
// (main() re-runs in the same isolate; static fields survive).
bool _loggingInitialized = false;
bool _posthogForwardingInitialized = false;

// Global navigator key for deep link navigation
// Note: This will be assigned from the router in RootProviderState.initState()
GlobalKey<NavigatorState>? _navigatorKey;

GlobalKey<NavigatorState>? get navigatorKey => _navigatorKey;

void setNavigatorKey(GlobalKey<NavigatorState> key) {
  _navigatorKey = key;
}

Future<void> run(List<String> args) async {
  // Initialize bindings first - required for platform channels used by Env.init()
  WidgetsFlutterBinding.ensureInitialized();

  // During hot restart or startup, Flutter may receive duplicate KeyDownEvents
  // for modifier keys held during the transition. The second event hits an
  // assertion in HardwareKeyboard and would break the keyboard pipeline.
  // Catch it here so the keyboard continues to work. Debug-only: assertions
  // are no-ops in release builds.
  PlatformDispatcher.instance.onError = (error, stack) {
    if (error is AssertionError &&
        stack.toString().contains('hardware_keyboard.dart')) {
      debugPrint(
        'Suppressed keyboard state assertion (hot restart artifact): $error',
      );
      return true; // Handled — keyboard state is still consistent
    }
    return false;
  };

  // On Windows, Dart's BoringSSL doesn't use the system certificate store,
  // causing CERTIFICATE_VERIFY_FAILED errors. Override to accept all certs
  // (matching browser behavior which uses the Windows cert store).
  if (!kIsWeb && Platform.isWindows) {
    HttpOverrides.global = _WindowsHttpOverrides();
  }

  // Initialize Firebase on mobile platforms (required for push notifications)
  if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      // Register background message handler before runApp
      FirebaseMessaging.onBackgroundMessage(handleBackgroundMessage);
    } catch (e, stackTrace) {
      // Firebase init is non-blocking — app works without push notifications
      log.warning('Firebase initialization failed', e, stackTrace);
    }
  }

  // Initialize deep link handling (iOS/Android only)
  if (!kIsWeb) {
    try {
      final appLinks = AppLinks();

      // Listen to incoming links while app is running
      appLinks.uriLinkStream.listen(
        (uri) async {
          log.info('Received deep link: $uri');

          // iOS ShareExtension callback — route through the share pipeline
          // instead of OpenPageLink (which expects a priority/thread URL).
          if (!kIsWeb && Platform.isIOS && _isIosShareDeepLink(uri)) {
            final content = await _readIosSharedContent(uri);
            if (content != null && content.isNotEmpty) {
              final shared = extractHttpUrl(content);
              if (shared != null) {
                log.info('iOS share deep link → extracted URL: $shared');
                final context = navigatorKey?.currentContext;
                if (context?.mounted == true) {
                  context!.run(OpenSharedLink(shared));
                } else {
                  PendingShare.url = shared;
                }
              } else {
                log.warning(
                  'iOS share deep link: no HTTP URL in content="$content"',
                );
              }
            } else {
              log.warning('iOS share deep link: no content in App Group');
            }
            return;
          }

          // Focus window first (desktop only)
          if (!kIsWeb && (Platform.isMacOS || Platform.isWindows)) {
            try {
              await windowManager.show();
              await windowManager.focus();
              await windowManager.restore();
            } catch (e) {
              log.warning('Failed to focus window', e);
            }
          }

          // Navigate to the deep link
          final context = navigatorKey?.currentContext;
          if (context?.mounted == true) {
            await OpenPageLink(uri.toString()).run(context!);
          } else {
            log.warning('Navigator context not available for deep link: $uri');
          }
        },
        onError: (Object err) {
          log.warning('Deep link error: $err');
        },
      );

      // Check for initial link (app was opened via link when not running)
      final initialUri = await appLinks.getInitialLink();
      if (initialUri != null) {
        log.info('App opened with deep link: $initialUri');
        // iOS cold-start share: pull content from App Group and buffer so the
        // router can replay it once ready.
        if (!kIsWeb && Platform.isIOS && _isIosShareDeepLink(initialUri)) {
          final content = await _readIosSharedContent(initialUri);
          final shared = content != null ? extractHttpUrl(content) : null;
          if (shared != null) {
            log.info('iOS cold-start share deep link → URL: $shared');
            PendingShare.url = shared;
          } else {
            log.warning(
              'iOS cold-start share deep link: no URL (content="$content")',
            );
          }
        }
        // Extract invite token so it survives until the router initializes
        final segments = initialUri.pathSegments;
        if (segments.length >= 2 && segments.first == 'invite') {
          PendingInvite.token = segments[1];
        }
      }

      // iOS scene-based cold-start share fallback. In scene mode iOS delivers
      // the share-extension URL via `scene(_:willConnectTo:options:)` only,
      // never `scene(_:openURLContexts:)`, and `app_links` only implements
      // `application(_:open:options:)` — so `getInitialLink()` returns null
      // and the share is lost. The ShareExtension always writes its payload
      // to App Group `UserDefaults["ShareKey"]` before opening the host, so
      // its presence on launch reliably indicates a fresh share.
      if (!kIsWeb && Platform.isIOS && PendingShare.url == null) {
        final content = await _readIosSharedContent(Uri.parse('share:?key=ShareKey'));
        final shared = content != null ? extractHttpUrl(content) : null;
        if (shared != null) {
          log.info('iOS cold-start share via App Group → URL: $shared');
          PendingShare.url = shared;
        }
      }
    } catch (error, stackTrace) {
      log.warning('Deep link initialization failed', error, stackTrace);
    }
  }

  // Initialize share intent handling (iOS/Android only)
  if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
    initShareIntent(
      onShareReceived: (url) {
        final context = navigatorKey?.currentContext;
        final mounted = context?.mounted == true;
        log.info(
          'onShareReceived: navigatorKey=${navigatorKey != null}, '
          'context=${context != null}, mounted=$mounted',
        );
        if (mounted) {
          log.info('onShareReceived: dispatching OpenSharedLink immediately');
          context!.run(OpenSharedLink(url));
        } else {
          log.info('onShareReceived: buffering via PendingShare.url');
          PendingShare.url = url;
        }
      },
    );
  }

  // On web, extract invite token from browser URL (equivalent of native getInitialLink)
  if (kIsWeb) {
    final segments = Uri.base.pathSegments;
    if (segments.length >= 2 && segments.first == 'invite') {
      PendingInvite.token = segments[1];
      log.info('Extracted invite token from web URL');
    }
  }

  // Initialize logging first
  try {
    hierarchicalLoggingEnabled = true;
    recordStackTraceAtLevel = Level.SEVERE;

    // INFO in all modes; use FINE temporarily when debugging specific issues
    Logger.root.level = Level.INFO;

    // Only register the listeners once per isolate. In debug mode, hot restart
    // re-runs main() but keeps static state — without this guard the listener
    // stack grows by one per restart, producing duplicate log output.
    if (!_loggingInitialized) {
      _loggingInitialized = true;
      Logger.root.onRecord.listen((record) {
        if ([
              LogNames.editor,
              LogNames.infrastructure,
              LogNames.textField,
              'attributions',
              'super_text',
            ].any((prefix) => record.loggerName.startsWith(prefix)) &&
            record.level < Level.WARNING) {
          return;
        }
        // ignore: avoid_print
        print(
          '${record.level.name}: ${record.loggerName.isEmpty ? 'plot' : record.loggerName}: ${record.message}',
        );
        if (record.error != null) {
          // ignore: avoid_print
          print(record.error);
        }
        if (record.stackTrace != null) {
          // ignore: avoid_print
          print(record.stackTrace);
        }
      });
    }

    // Initialize Env first so Tracker can be set up early
    await Env.init();

    // Initialize Tracker immediately after Env so it's ready to capture startup errors
    await Tracker.init();

    // Forward warning+ logs to PostHog in production (also guarded).
    if (!kDebugMode && !_posthogForwardingInitialized) {
      _posthogForwardingInitialized = true;
      Logger.root.onRecord.listen((record) {
        if (record.level < Level.WARNING) return;
        // Avoid infinite loop from Tracker's own logs
        if (record.loggerName == 'Tracker') return;
        Tracker.track('[Log] ${record.level.name}', {
          'logger':
              record.loggerName.isEmpty ? 'plot' : record.loggerName,
          'message': record.message,
          if (record.error != null) 'error': record.error.toString(),
          if (record.stackTrace != null)
            'stack_trace': extractStackTrace(record.stackTrace!),
        });
      });
    }
  } catch (error, stackTrace) {
    log.warning('Logging initialization failed', error, stackTrace);
    return runApp(ErrorApp(error: error.toString()));
  }

  try {
    // Parse command-line arguments early
    CliArgs.init(args);

    // Check for single-instance lock (desktop/mobile only)
    if (!kIsWeb) {
      final profile = CliArgs.profile ?? 'default';
      final instanceLock = InstanceLock(profile);

      if (!await instanceLock.tryAcquire()) {
        // Another instance is running, send deep link and exit
        final initialLink = await AppLinks().getInitialLink();
        final deepLink = CliArgs.url ?? initialLink?.toString();

        await instanceLock.sendDeepLinkRequest(deepLink);

        log.info(
          'Profile "$profile" already running. Sent deep link and exiting.',
        );
        exit(0);
      }

      // Store instance lock globally for cleanup
      _instanceLock = instanceLock;
    }

    // Set global SharedPreferences prefix for profile isolation.
    // This ensures ALL SharedPreferences usage (including Supabase auth)
    // is isolated per profile, not just our own keys.
    final profile = CliArgs.profile;
    if (profile != null) {
      SharedPreferences.setPrefix('flutter.profile.$profile.');
    }

    // Persist values needed by the background isolate (which can't load dotenv).
    // Must be after setPrefix to avoid "setPrefix after getInstance" error.
    if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('api_root', Env.apiRoot);
        await prefs.setString('clerk_publishable_key', Env.clerkPublishableKey);
      } catch (e) {
        log.warning('Failed to persist env values to SharedPreferences', e);
      }
    }

    // Initialize profile-aware preferences (must be after CliArgs, before Window)
    await ProfilePreferences.init();

    // Initialize Time early to support frozen time for testing/screenshots
    Time.init();

    await Window.init();
    await AppInfo.init();

    await Base.init();
    await AutoSignIn.init();
    await AuthButton.init();
    usePathUrlStrategy();

    // Start watching for deep link requests from other instances
    if (!kIsWeb && _instanceLock != null) {
      _instanceLock!.startWatching((deepLink) async {
        log.info('Received deep link from another instance: $deepLink');

        // Focus the window
        if (Platform.isMacOS || Platform.isWindows) {
          try {
            await windowManager.show();
            await windowManager.focus();
            await windowManager.restore();
          } catch (e) {
            log.warning('Failed to focus window from instance lock', e);
          }
        }

        // Navigate to deep link
        if (deepLink.isNotEmpty) {
          final context = navigatorKey?.currentContext;
          if (context?.mounted == true) {
            await OpenPageLink(deepLink).run(context!);
          } else {
            log.warning(
              'Navigator context not available for instance deep link: $deepLink',
            );
          }
        }
      });
    }

    log.info("Starting App");
    return runApp(const App());
  } catch (error, stackTrace) {
    log.warning('Startup failed', error, stackTrace);

    // Attempt to send error to Tracker if it was initialized before the error occurred
    try {
      await Tracker.captureException(error, stackTrace);
    } catch (e, t) {
      // Tracker not initialized or failed - error is already logged above
      log.warning('Could not send startup error to Tracker', e, t);
    }

    return runApp(ErrorApp(error: error.toString()));
  }
}

class _WindowsHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }
}

Future<void> main(List<String> args) async {
  await run(args);
}

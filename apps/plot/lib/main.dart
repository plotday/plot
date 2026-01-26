import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:logging/logging.dart';
import 'package:super_editor/super_editor.dart' show LogNames;
import 'package:app_links/app_links.dart';
import 'package:window_manager/window_manager.dart';

import 'analytics/tracker.dart';
import 'app.dart';
import 'app_info.dart';
import 'env.dart';
import 'auto_sign_in.dart';
import 'base.dart';
import 'cli_args.dart';
import 'logging.dart';
import 'widget/window.dart';
import 'widget/auth_button.dart';
import 'util/time_service.dart' show Time;
import 'util/profile_preferences.dart';
import 'util/instance_lock.dart';
import 'command/page_link.dart';

// Global instance lock for cleanup
InstanceLock? _instanceLock;

// Getter for instance lock (for cleanup in window.dart)
InstanceLock? get instanceLock => _instanceLock;

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

  // Initialize deep link handling (iOS/Android only)
  if (!kIsWeb) {
    try {
      final appLinks = AppLinks();

      // Listen to incoming links while app is running
      appLinks.uriLinkStream.listen((uri) async {
        log.info('Received deep link: $uri');

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
        if (context != null) {
          await OpenPageLink(uri.toString()).run(context);
        } else {
          log.warning('Navigator context not available for deep link: $uri');
        }
      }, onError: (Object err) {
        log.warning('Deep link error: $err');
      });

      // Check for initial link (app was opened via link when not running)
      final initialUri = await appLinks.getInitialLink();
      if (initialUri != null) {
        log.info('App opened with deep link: $initialUri');
        // The router will handle this automatically when it initializes
      }
    } catch (error, stackTrace) {
      log.warning('Deep link initialization failed', error, stackTrace);
    }
  }

  // Initialize logging first
  try {
    hierarchicalLoggingEnabled = true;
    recordStackTraceAtLevel = Level.SEVERE;

    // Configure log levels: INFO in production, FINE in debug for detailed logs
    Logger.root.level = kDebugMode ? Level.FINE : Level.INFO;

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

    // Initialize Env first so Tracker can be set up early
    await Env.init();

    // Initialize Tracker immediately after Env so it's ready to capture startup errors
    await Tracker.init();
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
          if (context != null) {
            await OpenPageLink(deepLink).run(context);
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

Future<void> main(List<String> args) async {
  await run(args);
}

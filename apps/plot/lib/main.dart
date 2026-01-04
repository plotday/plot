import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:logging/logging.dart';
import 'package:super_editor/super_editor.dart' show LogNames;
import 'package:posthog_flutter/posthog_flutter.dart';

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

Future<void> run(List<String> args) async {
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
    WidgetsFlutterBinding.ensureInitialized();

    // Parse command-line arguments early
    CliArgs.init(args);

    // Initialize Time early to support frozen time for testing/screenshots
    Time.init();

    // Initialize Env first so PostHog can be set up early
    await Env.init();

    // Initialize PostHog immediately after Env so it's ready to capture startup errors
    final config = PostHogConfig(Env.posthogApiKey)
      ..host = Env.posthogHost
      ..captureApplicationLifecycleEvents = true
      ..errorTrackingConfig.captureFlutterErrors = true
      ..personProfiles = PostHogPersonProfiles.identifiedOnly;
    await Posthog().setup(config);

    await Window.init();
    await AppInfo.init();

    await Base.init();
    await AutoSignIn.init();
    await AuthButton.init();
    usePathUrlStrategy();
    log.info("Starting App");
    return runApp(const App());
  } catch (error, stackTrace) {
    log.warning('Startup failed', error, stackTrace);

    // Attempt to send error to PostHog if it was initialized before the error occurred
    try {
      await Posthog().captureException(error: error, stackTrace: stackTrace);
    } catch (posthogError) {
      // PostHog not initialized or failed - error is already logged above
      log.fine('Could not send startup error to PostHog', posthogError);
    }

    return runApp(ErrorApp(error: error.toString()));
  }
}

Future<void> main(List<String> args) async {
  // Initialize PostHog with error tracking enabled
  FlutterError.onError = (FlutterErrorDetails details) async {
    log.severe('Uncaught Flutter error', details.exception, details.stack);
    await Posthog().captureException(
      error: details.exception,
      stackTrace: details.stack,
    );
    FlutterError.presentError(details);
  };

  // Catch async errors that occur outside of the Flutter framework
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    log.severe('Uncaught async error', error, stackTrace);
    Posthog().captureException(error: error, stackTrace: stackTrace);
    return true; // Marks the error as handled
  };

  await run(args);
}

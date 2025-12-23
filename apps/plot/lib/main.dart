import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:logging/logging.dart';
import 'package:super_editor/super_editor.dart' show LogNames;
import 'package:posthog_flutter/posthog_flutter.dart';

import 'app.dart';
import 'app_info.dart';
import 'env.dart';
import 'base.dart';
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

    // Initialize Time early to support frozen time for testing/screenshots
    Time.init(args);

    await Window.init();
    await Env.init();
    await AppInfo.init();

    // Initialize PostHog with environment variables
    final config = PostHogConfig(Env.posthogApiKey)
      ..host = Env.posthogHost
      ..captureApplicationLifecycleEvents = true
      ..errorTrackingConfig.captureFlutterErrors = true
      ..personProfiles = PostHogPersonProfiles.identifiedOnly;
    await Posthog().setup(config);

    await Base.init();
    await AuthButton.init();
    usePathUrlStrategy();
    log.info("Starting App");
    return runApp(const App());
  } catch (error, stackTrace) {
    log.warning('Startup failed', error, stackTrace);
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

  await run(args);
}

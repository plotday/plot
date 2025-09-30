import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:logging/logging.dart';
import 'package:super_editor/super_editor.dart' show LogNames;

import 'app.dart';
import 'env.dart';
import 'base.dart';
import 'logging.dart';
import 'widget/window.dart';
import 'widget/auth_button.dart';

Future<void> run() async {
  try {
    hierarchicalLoggingEnabled = true;
    recordStackTraceAtLevel = Level.SEVERE;
    Logger.root.onRecord.listen((record) {
      if ([
            LogNames.editor,
            LogNames.infrastructure,
            LogNames.textField,
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
    log.info("Starting window init");
    await Window.init();
    log.info("Done window init");
    await Env.init();
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

Future<void> main() async {
  if (kDebugMode) {
    await run();
  } else {
    await SentryFlutter.init((options) {
      options.dsn =
          "https://08fa5e400fac463fb57de5e33405db0b@o338620.ingest.sentry.io/4505551857057792";
    }, appRunner: run);
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app.dart';
import 'base.dart';

Future<void> run() async {
  try {
    await dotenv.load(fileName: ".env");
    await Base.init();
    usePathUrlStrategy();
    return runApp(const App());
  } on Error catch (error) {
    print(error);
    print(error.stackTrace);
    return runApp(ErrorApp(error: error.toString()));
  }
}

Future<void> main() async {
  if (kDebugMode) {
    await run();
  } else {
    await SentryFlutter.init(
      (options) {
        options.dsn =
            "https://08fa5e400fac463fb57de5e33405db0b@o338620.ingest.sentry.io/4505551857057792";
      },
      appRunner: run,
    );
  }
}

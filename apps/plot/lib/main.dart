import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app.dart';
import 'base.dart';
import 'store/store.dart';

Future<void> main() async {
  await SentryFlutter.init(
    (options) {
      options.dsn =
          "https://08fa5e400fac463fb57de5e33405db0b@o338620.ingest.sentry.io/4505551857057792";
      options.beforeSend = (event, hint) => kDebugMode ? null : event;
    },
    appRunner: () async {
      await dotenv.load(fileName: ".env");
      await Base.init();
      await Store.init();
      GoRouter.optionURLReflectsImperativeAPIs = true;
      usePathUrlStrategy();
      return runApp(const App());
    },
  );
}

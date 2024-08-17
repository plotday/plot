import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:ui';

import 'env.dart';
import 'app.dart';

Future<void> main() async {
  await SentryFlutter.init(
    (options) {
      options.dsn =
          "https://08fa5e400fac463fb57de5e33405db0b@o338620.ingest.sentry.io/4505551857057792";
    },
    appRunner: () async {
      await dotenv.load(fileName: ".env");
      await App.init();
      GoRouter.optionURLReflectsImperativeAPIs = true;
      usePathUrlStrategy();
      await Supabase.initialize(
        url: Env.supabaseUrl,
        anonKey: Env.supabaseAnonKey,
      );
      return runApp(const App());
    },
  );
  PlatformDispatcher.instance.onError = (error, stack) {
    print(error);
    print(stack);
    return true;
  };
}

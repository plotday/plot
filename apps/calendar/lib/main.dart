import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'env.dart';
import 'platform/app.dart';

Future<void> main() async {
  await App.init();

  GoRouter.optionURLReflectsImperativeAPIs = true;
  usePathUrlStrategy();
  await SentryFlutter.init(
    (options) {
      options.dsn = Env.sentryDsn;
    },
    appRunner: () async {
      await Supabase.initialize(
        url: Env.supabaseUrl,
        anonKey: Env.supabaseAnonKey,
      );
      return runApp(const App());
    },
  );
}

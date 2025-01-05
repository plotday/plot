import 'package:flutter_dotenv/flutter_dotenv.dart';

abstract class Env {
  static final String sentryDsn = dotenv.env['SENTRY_DSN']!;

  static final String supabaseUrl = dotenv.env['SUPABASE_URL']!;
  static final String supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY']!;

  static final String apiRoot = dotenv.env['API_ROOT']!;
  static final String authCallbackUrl = dotenv.env['AUTH_CALLBACK_URL']!;

  static final String googleClientId = dotenv.env['GOOGLE_CLIENT_ID']!;
  static final String googleIosClientId = dotenv.env['GOOGLE_IOS_CLIENT_ID']!;
  static final String googleAndroidClientId =
      dotenv.env['GOOGLE_ANDROID_CLIENT_ID']!;
}

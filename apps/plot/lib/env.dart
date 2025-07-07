import 'dart:io';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:device_info_plus/device_info_plus.dart';

abstract class Env {
  static Future<void> init() async {
    inAndroidEmulator = await _inAndroidEmuilator();
    await dotenv.load(fileName: ".env");

    sentryDsn = dotenv.env['SENTRY_DSN']!;

    supabaseUrl = _translateUrl(dotenv.env['SUPABASE_URL']!);
    supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY']!;

    apiRoot = dotenv.env['API_ROOT']!;
    authCallbackUrl = _translateUrl(dotenv.env['AUTH_CALLBACK_URL']!);

    googleClientId = dotenv.env['GOOGLE_CLIENT_ID']!;
    googleIosClientId = dotenv.env['GOOGLE_IOS_CLIENT_ID']!;
    googleAndroidClientId = dotenv.env['GOOGLE_ANDROID_CLIENT_ID']!;
  }

  static late final bool inAndroidEmulator;

  static String _translateUrl(String url) {
    if (inAndroidEmulator) {
      return url.replaceAll('localhost', '10.0.2.2');
    }
    return url;
  }

  static Future<bool> _inAndroidEmuilator() async {
    if (!Platform.isAndroid) return false;
    final DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();
    final AndroidDeviceInfo androidInfo = await deviceInfoPlugin.androidInfo;
    return !androidInfo.isPhysicalDevice;
  }

  static late final String sentryDsn;

  static late final String supabaseUrl;
  static late final String supabaseAnonKey;

  static late final String apiRoot;
  static late final String authCallbackUrl;

  static late final String googleClientId;
  static late final String googleIosClientId;
  static late final String googleAndroidClientId;
}

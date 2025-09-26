import 'dart:io';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

abstract class Env {
  static Future<void> init() async {
    inAndroidEmulator = await _inAndroidEmuilator();
    await dotenv.load(fileName: ".env");

    sentryDsn = dotenv.env['SENTRY_DSN']!;

    supabaseUrl = _translateUrl(dotenv.env['SUPABASE_URL']!);
    supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY']!;

    apiRoot = dotenv.env['API_ROOT']!;
    authServerCallbackUrl = dotenv.env['AUTH_GOOGLE_URI']!;
    authCallbackUrl = kIsWeb
        ? Uri.base.resolve('/auth.html').toString()
        : "plot-auth://callback";

    googleClientId = dotenv.env['AUTH_GOOGLE_ID']!;
    googleIosClientId = dotenv.env['AUTH_GOOGLE_IOS_ID']!;
    googleAndroidClientId = dotenv.env['AUTH_GOOGLE_ANDROID_ID']!;
  }

  static late final bool inAndroidEmulator;

  static String _translateUrl(String url) {
    if (inAndroidEmulator) {
      return url.replaceAll('localhost', '10.0.2.2');
    }
    return url;
  }

  static Future<bool> _inAndroidEmuilator() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    final DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();
    final AndroidDeviceInfo androidInfo = await deviceInfoPlugin.androidInfo;
    return !androidInfo.isPhysicalDevice;
  }

  static late final String sentryDsn;

  static late final String supabaseUrl;
  static late final String supabaseAnonKey;

  static late final String apiRoot;
  static late final String authCallbackUrl;
  static late final String authServerCallbackUrl;

  static late final String googleClientId;
  static late final String googleIosClientId;
  static late final String googleAndroidClientId;
}

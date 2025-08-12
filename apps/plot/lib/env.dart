import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

abstract class Env {
  static Future<void> init() async {
    inAndroidEmulator = await _inAndroidEmuilator();
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

  static const sentryDsn = String.fromEnvironment('SENTRY_DSN');

  static const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static String get supabaseUrl => _translateUrl(_supabaseUrl);
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static const _apiRoot = String.fromEnvironment('API_ROOT');
  static String get apiRoot => _translateUrl(_apiRoot);
  static const _authCallbackUrl = String.fromEnvironment('AUTH_CALLBACK_URL');
  static String get authCallbackUrl => _translateUrl(_authCallbackUrl);

  static const googleClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const googleIosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
  );
  static const googleAndroidClientId = String.fromEnvironment(
    'GOOGLE_ANDROID_CLIENT_ID',
  );
}

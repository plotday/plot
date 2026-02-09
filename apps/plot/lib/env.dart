import 'dart:io';
import 'package:flutter/foundation.dart';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

abstract class Env {
  static Future<void> init() async {
    inAndroidEmulator = await _inAndroidEmuilator();
    await dotenv.load(fileName: ".env");

    appBaseUrl = getEnvOrThrow('APP_ROOT');

    posthogApiKey = getEnvOrThrow('POSTHOG_API_KEY');
    posthogHost = getEnvOrThrow('POSTHOG_PROXY');

    supabaseUrl = _translateUrl(getEnvOrThrow('SUPABASE_URL'));
    supabaseAnonKey = getEnvOrThrow('SUPABASE_ANON_KEY');

    apiRoot = _translateUrl('${getEnvOrThrow('API_ROOT')}/app');
    authServerCallbackUrl = getEnvOrThrow('AUTH_GOOGLE_URI');
    authCallbackUrl = getEnvOrThrow('AUTH_CALLBACK_URL');

    googleClientId = getEnvOrThrow('AUTH_GOOGLE_ID');
    googleIosClientId = getEnvOrThrow('AUTH_GOOGLE_IOS_ID');
    googleAndroidClientId = getEnvOrThrow('AUTH_GOOGLE_ANDROID_ID');
    googleDesktopClientId = dotenv.maybeGet('AUTH_GOOGLE_DESKTOP_ID');
    googleClientSecret = dotenv.maybeGet('AUTH_GOOGLE_SECRET');
    // Use web service ID for web, native bundle ID for iOS/macOS/Android
    appleClientId = kIsWeb
        ? getEnvOrThrow('AUTH_APPLE_WEB_CLIENT_ID')
        : getEnvOrThrow('AUTH_APPLE_NATIVE_CLIENT_ID');
  }

  static late final bool inAndroidEmulator;

  static late final String appBaseUrl;

  static String _translateUrl(String url) {
    if (inAndroidEmulator) {
      return url.replaceAll(RegExp(r'(localhost|127\.0\.0\.1)'), '10.0.2.2');
    }
    return url;
  }

  static Future<bool> _inAndroidEmuilator() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    final DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();
    final AndroidDeviceInfo androidInfo = await deviceInfoPlugin.androidInfo;
    return !androidInfo.isPhysicalDevice;
  }

  static late final String posthogApiKey;
  static late final String posthogHost;

  static late final String supabaseUrl;
  static late final String supabaseAnonKey;

  static late final String apiRoot;
  static late final String authCallbackUrl;
  static late final String authServerCallbackUrl;

  static late final String googleClientId;
  static late final String googleIosClientId;
  static late final String googleAndroidClientId;
  static late final String? googleDesktopClientId;
  static late final String? googleClientSecret;
  static late final String appleClientId;

  static String getEnvOrThrow(String name) {
    final value = dotenv.maybeGet(name);
    if (value == null) {
      throw Exception('Missing environment variable: $name');
    }
    return value;
  }
}

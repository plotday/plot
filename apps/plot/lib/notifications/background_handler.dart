import 'dart:convert';
import 'dart:io';

import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/notifications/notification_display.dart';
import 'package:plot/notifications/notification_service.dart';
import 'package:plot/store/attention.dart';

/// Top-level background message handler registered with Firebase Messaging.
///
/// Runs in a separate isolate when the app is backgrounded or terminated.
/// Fetches fresh notification content from the API and shows (or schedules)
/// a local notification.
@pragma('vm:entry-point')
Future<void> handleBackgroundMessage(RemoteMessage message) async {
  if (message.data['type'] != 'sync_wake') return;

  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final apiRoot = prefs.getString('api_root');
  final publishableKey = prefs.getString('clerk_publishable_key');
  final userId = prefs.getString('notification_user_id');
  if (apiRoot == null || publishableKey == null || userId == null) return;

  // Obtain a fresh session token using Clerk's persisted cache
  final token = await _getSessionToken(publishableKey);
  if (token == null) return;

  // Fetch up-to-date notification summaries from the API
  final summaries = await _fetchNotificationContent(apiRoot, token);
  if (summaries == null || summaries.isEmpty) return;

  // Initialize local notification display
  await NotificationDisplay.instance.initialize();

  // Check whether we're currently in quiet hours
  final scheduleAt = _computeNotifyTime(prefs);
  if (scheduleAt != null) {
    // Quiet hours: show notifications when they end
    await _scheduleNotifications(summaries, scheduleAt);
  } else {
    await showSummaryNotifications(summaries);
  }
}

/// Obtain a Clerk session token using the persisted cache from the main app.
Future<String?> _getSessionToken(String publishableKey) async {
  try {
    final cacheDir = await _getClerkCacheDirectory();
    final persistor = clerk.DefaultPersistor(
      getCacheDirectory: () async => cacheDir,
    );
    final auth = clerk.Auth(
      config: clerk.AuthConfig(
        publishableKey: publishableKey,
        persistor: persistor,
      ),
    );
    await auth.initialize().timeout(const Duration(seconds: 10));
    final token = await auth.sessionToken();
    auth.terminate();
    return token.jwt;
  } catch (_) {
    return null;
  }
}

/// Locate the Clerk cache directory (same path as the main app uses).
Future<Directory> _getClerkCacheDirectory() async {
  final appSupport = await getApplicationSupportDirectory();
  final dir = Directory('${appSupport.path}/clerk');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// Fetch notification summaries from GET /notification-content.
Future<List<Map<String, dynamic>>?> _fetchNotificationContent(
  String apiRoot,
  String token,
) async {
  try {
    final uri = Uri.parse('$apiRoot/notification-content');
    final response = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) return null;

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final summaries = body['summaries'] as List?;
    return summaries?.cast<Map<String, dynamic>>();
  } catch (_) {
    return null;
  }
}

/// Returns the [DateTime] at which notifications should be shown if quiet
/// hours are currently in effect, or null if notifications should show now.
DateTime? _computeNotifyTime(SharedPreferences prefs) {
  try {
    final windowsJson = prefs.getString('attention_windows');
    final List<AttentionWindow> windows;
    if (windowsJson != null) {
      windows = AttentionWindow.fromJsonString(windowsJson) ?? [];
    } else {
      windows = AttentionWindow.defaultQuietHours;
    }

    if (windows.isEmpty) return null;

    final now = DateTime.now();
    final dayOfWeek = now.weekday; // 1=Mon..7=Sun
    final currentMinutes = now.hour * 60 + now.minute;

    // Check if now is inside a quiet window (i.e., NOT in an attention window)
    // Quiet hours are the periods outside all attention windows.
    // If the windows list represents quiet hours (default: 9pm–7am daily),
    // we check whether now falls inside any window.
    for (final w in windows) {
      if (!w.days.contains(dayOfWeek)) continue;
      final startParts = w.start.split(':');
      final endParts = w.end.split(':');
      final startMinutes =
          int.parse(startParts[0]) * 60 + int.parse(startParts[1]);
      final endMinutes = int.parse(endParts[0]) * 60 + int.parse(endParts[1]);

      final inWindow = startMinutes < endMinutes
          ? currentMinutes >= startMinutes && currentMinutes < endMinutes
          : currentMinutes >= startMinutes || currentMinutes < endMinutes;

      if (inWindow) {
        // We're in a quiet window — compute when it ends
        if (startMinutes < endMinutes) {
          // Same-day window
          return DateTime(
            now.year,
            now.month,
            now.day,
            endMinutes ~/ 60,
            endMinutes % 60,
          );
        } else {
          // Window crosses midnight — end is next day
          final tomorrow = now.add(const Duration(days: 1));
          return DateTime(
            tomorrow.year,
            tomorrow.month,
            tomorrow.day,
            endMinutes ~/ 60,
            endMinutes % 60,
          );
        }
      }
    }
    return null; // Not in quiet hours, notify immediately
  } catch (_) {
    return null;
  }
}

/// Schedule notifications to appear at [scheduleAt] using delayed delivery.
///
/// Since timezone-based scheduling requires full timezone initialization
/// (unsuitable for a background isolate), this uses a simple Future.delayed
/// approach. Note: this won't survive process termination — for a more robust
/// implementation, use flutter_local_notifications zonedSchedule() with the
/// timezone package initialized.
Future<void> _scheduleNotifications(
  List<Map<String, dynamic>> summaries,
  DateTime scheduleAt,
) async {
  final delay = scheduleAt.difference(DateTime.now());
  if (delay <= Duration.zero) {
    await showSummaryNotifications(summaries);
    return;
  }
  await Future.delayed(delay, () => showSummaryNotifications(summaries));
}

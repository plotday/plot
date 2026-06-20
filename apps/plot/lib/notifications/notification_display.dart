import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'package:plot/logging.dart';

/// Notification channel IDs for Android. Just two now: a high-priority
/// "urgent" channel for threads flagged `urgent`, and a default channel
/// for everything else above the importance gate.
class _Channels {
  static const urgent = 'urgent';
  static const updates = 'updates';
}

/// Manages local notification display via flutter_local_notifications.
///
/// On mobile, the app receives silent FCM data messages, syncs data locally,
/// then uses this service to display local notifications.
/// On desktop, notifications are triggered by WebSocket sync completions.
class NotificationDisplay {
  static final NotificationDisplay _instance = NotificationDisplay._();
  static NotificationDisplay get instance => _instance;
  NotificationDisplay._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  static bool _timezoneInitialized = false;

  /// Callback for when a notification is tapped.
  /// Receives the notification payload (target_priority_id).
  void Function(String? payload)? onNotificationTap;

  /// Check if the app was launched by tapping a local notification (cold start).
  /// Returns the payload (target_priority_id) or null if not launched from a notification.
  Future<String?> getLaunchNotification() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return details.notificationResponse?.payload;
  }

  /// Initialize timezone data for scheduling. Safe to call from background
  /// isolates — timezone data is embedded in the package, no I/O needed.
  static Future<void> initializeTimezone() async {
    if (_timezoneInitialized) return;
    tz.initializeTimeZones();
    try {
      final timezoneInfo = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezoneInfo.identifier));
    } catch (_) {
      // Fallback: use UTC if device timezone can't be determined
    }
    _timezoneInitialized = true;
  }

  /// Initialize the local notification plugin with platform-specific settings.
  Future<void> initialize() async {
    if (_initialized) return;
    if (kIsWeb) return;
    if (!(Platform.isIOS || Platform.isAndroid || Platform.isMacOS || Platform.isWindows)) return;

    const androidSettings = AndroidInitializationSettings('ic_stat_notification');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const macOSSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: macOSSettings,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    // Create Android notification channels
    if (Platform.isAndroid) {
      final androidPlugin =
          _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        // Delete old channels from previous urgency schemes
        await androidPlugin.deleteNotificationChannel('inform_fast');
        await androidPlugin.deleteNotificationChannel('inform_slow');
        await androidPlugin.deleteNotificationChannel('interrupt');
        await androidPlugin.deleteNotificationChannel('inform_requests');
        await androidPlugin.deleteNotificationChannel('inform_updates');

        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            _Channels.urgent,
            'Urgent',
            description: 'Notifications that need immediate attention',
            importance: Importance.high,
          ),
        );
        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            _Channels.updates,
            'Updates',
            description: 'General updates worth reviewing',
            importance: Importance.defaultImportance,
          ),
        );
      }
    }

    _initialized = true;
  }

  void _onNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    log.info('Notification tapped with payload: $payload');
    onNotificationTap?.call(payload);
  }

  /// Request POST_NOTIFICATIONS permission on Android 13+.
  /// Returns true if permission was granted.
  Future<bool> requestAndroidPermission() async {
    if (!Platform.isAndroid) return false;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;
    final granted = await android.requestNotificationsPermission();
    return granted ?? false;
  }

  /// Request notification permission on macOS explicitly.
  /// Returns true if permission was granted.
  Future<bool> requestMacOSPermission() async {
    if (!Platform.isMacOS) return false;
    final macOS = _plugin.resolvePlatformSpecificImplementation<
        MacOSFlutterLocalNotificationsPlugin>();
    if (macOS == null) return false;
    final granted = await macOS.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
    return granted ?? false;
  }

  /// Query the current macOS notification settings from the OS.
  Future<Map<String, String>?> getNotificationSettings() async {
    if (!Platform.isMacOS) return null;
    final macOS = _plugin.resolvePlatformSpecificImplementation<
        MacOSFlutterLocalNotificationsPlugin>();
    if (macOS == null) return null;
    final result = await macOS.checkPermissions();
    if (result == null) return null;
    return {
      'enabled': '${result.isEnabled}',
      'alert': '${result.isAlertEnabled}',
      'badge': '${result.isBadgeEnabled}',
      'sound': '${result.isSoundEnabled}',
    };
  }

  /// Show a notification for a batch of updates.
  ///
  /// [focusLabel] is the "Role › Focus" crumb (see `buildFocusLabel`); when
  /// non-null it renders in the notification header — Android `subText`, iOS /
  /// macOS `subtitle` — so the user can tell which focus the update belongs to.
  Future<void> showBatchNotification({
    required int id,
    required String title,
    required String body,
    required String targetPriorityId,
    String? focusLabel,
    bool urgent = false,
  }) async {
    if (!_initialized) return;

    final channelId = urgent ? _Channels.urgent : _Channels.updates;
    final importance =
        urgent ? Importance.high : Importance.defaultImportance;
    final priority = urgent ? Priority.high : Priority.defaultPriority;

    final androidDetails = AndroidNotificationDetails(
      channelId,
      urgent ? 'Urgent' : 'Updates',
      importance: importance,
      priority: priority,
      autoCancel: true,
      onlyAlertOnce: true,
      icon: 'ic_stat_notification',
      color: const Color(0xFF239870),
      subText: focusLabel,
    );

    final darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      subtitle: focusLabel,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    await _plugin.show(
      id,
      title,
      body,
      details,
      payload: targetPriorityId,
    );
  }

  /// Schedule a notification to appear at [scheduleAt].
  ///
  /// Uses Android AlarmManager / iOS scheduling under the hood, so it
  /// persists across process termination. Call [initializeTimezone] before
  /// using this method.
  Future<void> scheduleBatchNotification({
    required int id,
    required String title,
    required String body,
    required String targetPriorityId,
    required DateTime scheduleAt,
    String? focusLabel,
    bool urgent = false,
  }) async {
    if (!_initialized) return;

    final channelId = urgent ? _Channels.urgent : _Channels.updates;
    final importance =
        urgent ? Importance.high : Importance.defaultImportance;
    final priority = urgent ? Priority.high : Priority.defaultPriority;

    final androidDetails = AndroidNotificationDetails(
      channelId,
      urgent ? 'Urgent' : 'Updates',
      importance: importance,
      priority: priority,
      autoCancel: true,
      onlyAlertOnce: true,
      icon: 'ic_stat_notification',
      color: const Color(0xFF239870),
      subText: focusLabel,
    );

    final darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      subtitle: focusLabel,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    final tzScheduleAt = tz.TZDateTime.from(scheduleAt, tz.local);

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tzScheduleAt,
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: targetPriorityId,
    );
  }

  /// Cancel a specific notification by id.
  Future<void> cancel(int id) async {
    if (!_initialized) return;
    await _plugin.cancel(id);
  }

  /// Cancel all displayed notifications.
  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
  }
}

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'package:plot/logging.dart';

/// Notification channel IDs for Android urgency levels.
class _Channels {
  static const interrupt = 'interrupt';
  static const informRequests = 'inform_requests';
  static const informUpdates = 'inform_updates';
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

  /// Initialize timezone data for scheduling. Safe to call from background
  /// isolates — timezone data is embedded in the package, no I/O needed.
  static Future<void> initializeTimezone() async {
    if (_timezoneInitialized) return;
    tz.initializeTimeZones();
    try {
      final timezoneName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezoneName));
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
        // Delete old channels from previous urgency scheme
        await androidPlugin.deleteNotificationChannel('inform_fast');
        await androidPlugin.deleteNotificationChannel('inform_slow');

        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            _Channels.interrupt,
            'Urgent',
            description: 'Notifications that need immediate attention',
            importance: Importance.high,
          ),
        );
        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            _Channels.informRequests,
            'Requests',
            description: 'Someone is waiting on you',
            importance: Importance.defaultImportance,
          ),
        );
        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            _Channels.informUpdates,
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

  /// Show a notification for a batch of updates.
  Future<void> showBatchNotification({
    required int id,
    required String title,
    required String body,
    required String targetPriorityId,
    String urgency = 'inform-updates',
  }) async {
    if (!_initialized) return;

    final channelId = switch (urgency) {
      'interrupt' => _Channels.interrupt,
      'inform-requests' => _Channels.informRequests,
      _ => _Channels.informUpdates,
    };

    final importance = switch (urgency) {
      'interrupt' => Importance.high,
      _ => Importance.defaultImportance,
    };

    final priority = switch (urgency) {
      'interrupt' => Priority.high,
      _ => Priority.defaultPriority,
    };

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelId == _Channels.interrupt
          ? 'Urgent'
          : channelId == _Channels.informRequests
              ? 'Requests'
              : 'Updates',
      importance: importance,
      priority: priority,
      autoCancel: true,
      icon: 'ic_stat_notification',
      color: const Color(0xFF239870),
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
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
    String urgency = 'inform-updates',
  }) async {
    if (!_initialized) return;

    final channelId = switch (urgency) {
      'interrupt' => _Channels.interrupt,
      'inform-requests' => _Channels.informRequests,
      _ => _Channels.informUpdates,
    };

    final importance = switch (urgency) {
      'interrupt' => Importance.high,
      _ => Importance.defaultImportance,
    };

    final priority = switch (urgency) {
      'interrupt' => Priority.high,
      _ => Priority.defaultPriority,
    };

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelId == _Channels.interrupt
          ? 'Urgent'
          : channelId == _Channels.informRequests
              ? 'Requests'
              : 'Updates',
      importance: importance,
      priority: priority,
      autoCancel: true,
      icon: 'ic_stat_notification',
      color: const Color(0xFF239870),
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
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

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:plot/logging.dart';

/// Notification channel IDs for Android urgency levels.
class _Channels {
  static const interrupt = 'interrupt';
  static const informRequests = 'inform_requests';
  static const informUpdates = 'inform_updates';
}

/// Manages local notification display via flutter_local_notifications.
///
/// The app receives silent FCM data messages, syncs data locally,
/// then uses this service to display local notifications.
class NotificationDisplay {
  static final NotificationDisplay _instance = NotificationDisplay._();
  static NotificationDisplay get instance => _instance;
  NotificationDisplay._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Callback for when a notification is tapped.
  /// Receives the notification payload (target_priority_id).
  void Function(String? payload)? onNotificationTap;

  /// Initialize the local notification plugin with platform-specific settings.
  Future<void> initialize() async {
    if (_initialized) return;
    if (kIsWeb || !(Platform.isIOS || Platform.isAndroid)) return;

    const androidSettings = AndroidInitializationSettings('ic_stat_notification');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
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
            importance: Importance.low,
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
      'inform-requests' => Importance.defaultImportance,
      _ => Importance.low,
    };

    final priority = switch (urgency) {
      'interrupt' => Priority.high,
      'inform-requests' => Priority.defaultPriority,
      _ => Priority.low,
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

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      id,
      title,
      body,
      details,
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

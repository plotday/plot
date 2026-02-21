import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'package:plot/api/api.dart' as api;
import 'package:plot/app_info.dart';
import 'package:plot/logging.dart';

/// Manages push notification token registration and message handling.
///
/// Call [start] after sign-in and [stop] on sign-out.
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  static NotificationService get instance => _instance;
  NotificationService._();

  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _messageOpenedSubscription;
  String? _currentToken;

  /// Whether push notifications are supported on this platform.
  static bool get isSupported => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  /// Initialize Firebase Messaging, request permissions, and register the
  /// device token with the API. Call after Firebase.initializeApp() and
  /// after the user has signed in.
  Future<void> start() async {
    if (!isSupported) return;

    final messaging = FirebaseMessaging.instance;

    // Request permission (shows system dialog on iOS; requests
    // POST_NOTIFICATIONS on Android 13+)
    try {
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        log.info('Push notification permission denied by user');
        return;
      }
    } catch (e) {
      log.warning('Failed to request notification permission', e);
      return;
    }

    // Get current token and register
    try {
      final token = await messaging.getToken();
      if (token != null) {
        _currentToken = token;
        await _registerToken(token);
      }
    } catch (e) {
      log.warning('Failed to get FCM token', e);
    }

    // Listen for token refresh
    _tokenRefreshSubscription =
        messaging.onTokenRefresh.listen((token) async {
      _currentToken = token;
      try {
        await _registerToken(token);
      } catch (e) {
        log.warning('Failed to register refreshed FCM token', e);
      }
    });

    // Foreground message handler (log for now; display behavior designed later)
    _foregroundSubscription =
        FirebaseMessaging.onMessage.listen((message) {
      log.info(
        'Foreground notification: ${message.notification?.title}',
      );
    });

    // Notification tap handler (app was in background)
    _messageOpenedSubscription =
        FirebaseMessaging.onMessageOpenedApp.listen((message) {
      log.info(
        'Notification tapped: ${message.notification?.title}',
      );
      _handleNotificationTap(message);
    });

    // Check if app was opened from a terminated state via notification
    try {
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        log.info(
          'App opened from notification: ${initialMessage.notification?.title}',
        );
        _handleNotificationTap(initialMessage);
      }
    } catch (e) {
      log.warning('Failed to get initial notification message', e);
    }
  }

  /// Deregister the device token and clean up listeners.
  /// Call on sign-out.
  Future<void> stop() async {
    if (!isSupported) return;

    // Cancel listeners first
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
    await _foregroundSubscription?.cancel();
    _foregroundSubscription = null;
    await _messageOpenedSubscription?.cancel();
    _messageOpenedSubscription = null;

    // Deregister the token from the API
    if (_currentToken != null) {
      try {
        await api.deleteWithBody<Map<String, dynamic>>('/device', body: {
          'pushToken': _currentToken!,
        });
      } catch (e) {
        log.warning('Failed to deregister device token', e);
      }
      _currentToken = null;
    }
  }

  Future<void> _registerToken(String token) async {
    final platform = Platform.isIOS ? 'ios' : 'android';
    await api.put<Map<String, dynamic>>('/device', body: {
      'platform': platform,
      'pushToken': token,
      'appVersion': '${AppInfo.version}+${AppInfo.buildNumber}',
    });
    log.info('Device token registered ($platform)');
  }

  void _handleNotificationTap(RemoteMessage message) {
    // Navigation logic to be designed later.
    // Will use message.data to determine which screen to open.
  }
}

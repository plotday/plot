import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'package:plot/api/api.dart' as api;
import 'package:plot/api/broadcast.dart';
import 'package:plot/app_info.dart';
import 'package:plot/logging.dart';
import 'package:plot/notifications/notification_display.dart';
import 'package:plot/store/attention.dart';
import 'package:plot/store/store.dart';

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

  /// Tracks notifications that have been shown: priorityId → notification id.
  /// Used for retraction when threads are read on another device.
  final Map<String, int> _shownNotifications = {};

  static const Duration _suppressionWindow = Duration(minutes: 5);

  /// Callback for navigating to a priority when a notification is tapped.
  void Function(String priorityId)? onNavigateToPriority;

  /// Whether push notifications are supported on this platform.
  static bool get isSupported => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  /// Initialize Firebase Messaging, request permissions, and register the
  /// device token with the API. Call after Firebase.initializeApp() and
  /// after the user has signed in.
  Future<void> start() async {
    if (!isSupported) return;

    // Initialize local notification display
    await NotificationDisplay.instance.initialize();
    NotificationDisplay.instance.onNotificationTap = _handlePayloadTap;

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

    // Data message handler — triggers sync and local notification display
    _foregroundSubscription =
        FirebaseMessaging.onMessage.listen(_handleDataMessage);

    // Notification tap handler (app was in background)
    _messageOpenedSubscription =
        FirebaseMessaging.onMessageOpenedApp.listen((message) {
      log.info('Notification tapped: ${message.data}');
      _handleNotificationTap(message);
    });

    // Check if app was opened from a terminated state via notification
    try {
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        log.info('App opened from notification: ${initialMessage.data}');
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

  /// Handle incoming FCM data messages (silent push from server).
  Future<void> _handleDataMessage(RemoteMessage message) async {
    final type = message.data['type'];
    if (type != 'sync_wake') return;

    log.info('Received sync_wake push notification');

    try {
      // 1. Trigger a data sync
      final store = Store.get;
      await SyncOrchestrator.instance.syncAll();

      // 2. Query local DB for unread threads grouped by first-level priority
      final batches = await _buildNotificationBatches(store);

      // 3. Retract any notifications whose threads have since been read
      await _retractStaleNotifications(batches);

      if (batches.isEmpty) return;

      // 4. Check if another device was recently active — suppress if so
      await _checkAndShowNotifications(batches, store);
    } catch (e) {
      log.warning('Error handling sync_wake notification', e);
    }
  }

  /// Suppress notifications if another device was active within the last 5
  /// minutes. Re-checks once the window expires, then shows if still unread.
  Future<void> _checkAndShowNotifications(
    List<NotificationBatch> batches,
    Store store,
  ) async {
    try {
      final clientId = BroadcastClient.instance.clientId;
      final query = clientId != null ? '?excludeClient=$clientId' : '';
      final response = await api.get<Map<String, dynamic>>(
        '/device/others-active$query',
      );
      final lastActiveAtStr = response['lastActiveAt'] as String?;

      if (lastActiveAtStr != null) {
        final lastActiveAt = DateTime.tryParse(lastActiveAtStr);
        if (lastActiveAt != null) {
          final age = DateTime.now().toUtc().difference(lastActiveAt);
          if (age < _suppressionWindow) {
            // Another device was recently active — wait out the window then retry
            final remaining = _suppressionWindow - age;
            log.info(
              'Suppressing notification: another device active '
              '${age.inSeconds}s ago; retrying in ${remaining.inSeconds}s',
            );
            Timer(remaining, () async {
              try {
                final freshBatches = await _buildNotificationBatches(store);
                await _retractStaleNotifications(freshBatches);
                if (freshBatches.isNotEmpty) {
                  await _showBatches(freshBatches);
                }
              } catch (e) {
                log.warning('Error in delayed notification check', e);
              }
            });
            return;
          }
        }
      }
    } catch (e) {
      // If the suppression check fails, fall through and show notifications
      log.warning('Failed to check others-active, showing notification', e);
    }

    await _showBatches(batches);
  }

  /// Show notifications from batches, fetching AI summaries when possible.
  Future<void> _showBatches(List<NotificationBatch> batches) async {
    final summaries = await _fetchSummaries(batches);
    if (summaries == null) {
      await _showFallbackNotifications(batches);
      return;
    }
    await _showNotifications(summaries);
  }

  /// Cancel any shown notifications whose priority no longer has unread threads.
  /// Pass the fresh batch list from [_buildNotificationBatches] to compare.
  Future<void> _retractStaleNotifications(
    List<NotificationBatch> freshBatches,
  ) async {
    if (_shownNotifications.isEmpty) return;

    final freshPriorityIds = freshBatches
        .map((b) => b.targetPriorityId ?? b.firstLevelPriorityId)
        .toSet();

    final staleKeys = <String>[];
    for (final entry in _shownNotifications.entries) {
      if (!freshPriorityIds.contains(entry.key)) {
        await NotificationDisplay.instance.cancel(entry.value);
        staleKeys.add(entry.key);
      }
    }
    for (final key in staleKeys) {
      _shownNotifications.remove(key);
    }
  }

  /// Build notification batches from local unread thread data.
  /// Groups by first-level priority (direct children of root).
  Future<List<NotificationBatch>> _buildNotificationBatches(Store store) async {
    // Get all unread threads with their priority info
    final unreadRows = await (store.select(store.threads)
          ..where((t) => t.unread.equals(true)))
        .get();

    if (unreadRows.isEmpty) return [];

    // Get all priorities to resolve first-level grouping
    final allPriorities = await store.select(store.priorities).get();
    final priorityById = {for (final p in allPriorities) p.id.value.toString(): p};

    // Find the root priority
    final rootPriority = allPriorities
        .where((p) => p.root)
        .firstOrNull;
    if (rootPriority == null) return [];

    final rootPath = rootPriority.path.value;

    // Group unread threads by first-level priority
    final Map<String, NotificationBatch> batchMap = {};

    for (final thread in unreadRows) {
      // passive threads show unread in-app but don't generate push notifications
      if (thread.urgency == 'passive') continue;

      final priorityIdStr = thread.priorityId.value.toString();
      final priority = priorityById[priorityIdStr];
      if (priority == null) continue;

      // Find the first-level priority (direct child of root)
      final firstLevel = _findFirstLevelPriority(
        priority.path.value, rootPath, allPriorities,
      );
      if (firstLevel == null) continue;

      final firstLevelIdStr = firstLevel.id.value.toString();

      final batch = batchMap.putIfAbsent(
        firstLevelIdStr,
        () => NotificationBatch(
          firstLevelPriorityId: firstLevelIdStr,
          priorityTitle: firstLevel.title,
          threads: [],
          highestUrgency: 'inform-updates',
          attentionWindow: firstLevel.attentionWindow != null
              ? AttentionWindow.fromJsonString(firstLevel.attentionWindow)
              : null,
        ),
      );

      batch.threads.add(NotificationThread(
        id: thread.id.value.toString(),
        title: thread.title,
        preview: thread.preview,
        urgency: thread.urgency ?? 'inform-updates',
        priorityId: priorityIdStr,
      ));

      // Track highest urgency in batch
      if (_urgencyRank(thread.urgency) < _urgencyRank(batch.highestUrgency)) {
        batch.highestUrgency = thread.urgency ?? 'inform-updates';
      }
    }

    // For each batch, compute the target priority (lowest common ancestor)
    for (final batch in batchMap.values) {
      batch.targetPriorityId = _computeTargetPriority(
        batch.threads.map((t) => t.priorityId).toSet(),
        priorityById,
        batch.firstLevelPriorityId,
      );
    }

    return batchMap.values.toList();
  }

  /// Find the first-level priority (direct child of root) for a given path.
  PriorityRow? _findFirstLevelPriority(
    String threadPriorityPath,
    String rootPath,
    List<PriorityRow> allPriorities,
  ) {
    // First-level priority path has exactly one more segment than root
    // e.g., root = "abc", first-level = "abc.work"
    final rootSegments = rootPath.split('.');
    final pathSegments = threadPriorityPath.split('.');

    if (pathSegments.length <= rootSegments.length) return null;

    // Build the first-level path
    final firstLevelPath = pathSegments.sublist(0, rootSegments.length + 1).join('.');

    return allPriorities
        .where((p) => p.path.value == firstLevelPath)
        .firstOrNull;
  }

  /// Compute the lowest common ancestor priority that contains all thread priorities.
  String _computeTargetPriority(
    Set<String> priorityIds,
    Map<String, PriorityRow> priorityById,
    String fallbackId,
  ) {
    if (priorityIds.length == 1) return priorityIds.first;

    // Get paths for all priorities
    final paths = priorityIds
        .map((id) => priorityById[id]?.path.value)
        .whereType<String>()
        .toList();

    if (paths.isEmpty) return fallbackId;

    // Find common prefix of all paths
    final segments = paths.map((p) => p.split('.')).toList();
    final minLength = segments.map((s) => s.length).reduce((a, b) => a < b ? a : b);

    int commonLength = 0;
    for (int i = 0; i < minLength; i++) {
      final segment = segments[0][i];
      if (segments.every((s) => s[i] == segment)) {
        commonLength = i + 1;
      } else {
        break;
      }
    }

    if (commonLength == 0) return fallbackId;

    final commonPath = segments[0].sublist(0, commonLength).join('.');
    final match = priorityById.values
        .where((p) => p.path.value == commonPath)
        .firstOrNull;

    return match?.id.value.toString() ?? fallbackId;
  }

  /// Fetch AI-generated summaries from the API.
  Future<List<Map<String, dynamic>>?> _fetchSummaries(
    List<NotificationBatch> batches,
  ) async {
    try {
      final response = await api.post<Map<String, dynamic>>(
        '/notification-summary',
        body: {
          'batches': batches.map((b) {
            return {
              'first_level_priority_id': b.firstLevelPriorityId,
              'priority_title': b.priorityTitle,
              'target_priority_id': b.targetPriorityId,
              'threads': b.threads.take(10).map((t) {
                return {
                  'id': t.id,
                  'title': t.title,
                  'preview': t.preview,
                };
              }).toList(),
            };
          }).toList(),
        },
      );

      final summaries = response['summaries'] as List?;
      return summaries?.cast<Map<String, dynamic>>();
    } catch (e) {
      log.warning('Failed to fetch notification summaries', e);
      return null;
    }
  }

  /// Show notifications using AI-generated summaries.
  Future<void> _showNotifications(List<Map<String, dynamic>> summaries) async {
    for (var i = 0; i < summaries.length; i++) {
      final summary = summaries[i];
      final title = summary['title'] as String? ?? 'Updates';
      final body = summary['body'] as String? ?? 'You have new updates';
      final targetPriorityId = summary['target_priority_id'] as String? ?? '';

      await NotificationDisplay.instance.showBatchNotification(
        id: i,
        title: title,
        body: body,
        targetPriorityId: targetPriorityId,
      );
      if (targetPriorityId.isNotEmpty) {
        _shownNotifications[targetPriorityId] = i;
      }
    }
  }

  /// Fallback: show simple notifications without AI summary.
  Future<void> _showFallbackNotifications(List<NotificationBatch> batches) async {
    for (var i = 0; i < batches.length; i++) {
      final batch = batches[i];
      final title = batch.priorityTitle ?? 'Updates';
      final body = batch.threads.length == 1
          ? batch.threads.first.title ?? 'New update'
          : '${batch.threads.length} new updates';

      final displayId = batch.targetPriorityId ?? batch.firstLevelPriorityId;
      await NotificationDisplay.instance.showBatchNotification(
        id: i,
        title: title,
        body: body,
        targetPriorityId: displayId,
        urgency: batch.highestUrgency,
      );
      _shownNotifications[displayId] = i;
    }
  }

  int _urgencyRank(String? urgency) => switch (urgency) {
    'interrupt' => 0,
    'inform-requests' => 1,
    'inform-updates' => 2,
    'passive' => 3,
    _ => 4,
  };

  void _handleNotificationTap(RemoteMessage message) {
    final targetPriorityId = message.data['target_priority_id'] as String?;
    if (targetPriorityId != null) {
      _handlePayloadTap(targetPriorityId);
    }
  }

  void _handlePayloadTap(String? payload) {
    if (payload != null && payload.isNotEmpty) {
      onNavigateToPriority?.call(payload);
    }
  }
}

/// A batch of unread threads for a single first-level priority.
class NotificationBatch {
  final String firstLevelPriorityId;
  final String? priorityTitle;
  final List<NotificationThread> threads;
  String highestUrgency;
  String? targetPriorityId;
  final List<AttentionWindow>? attentionWindow;

  NotificationBatch({
    required this.firstLevelPriorityId,
    required this.priorityTitle,
    required this.threads,
    required this.highestUrgency,
    this.targetPriorityId,
    this.attentionWindow,
  });
}

/// A single unread thread within a notification batch.
class NotificationThread {
  final String id;
  final String? title;
  final String? preview;
  final String urgency;
  final String priorityId;

  NotificationThread({
    required this.id,
    required this.title,
    required this.preview,
    required this.urgency,
    required this.priorityId,
  });
}

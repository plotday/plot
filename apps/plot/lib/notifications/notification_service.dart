import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/broadcast.dart';
import 'package:plot/app_info.dart';
import 'package:plot/logging.dart';
import 'package:plot/notifications/notification_display.dart';
import 'package:plot/notifications/notification_quiet_hours.dart';
import 'package:plot/store/attention.dart';
import 'package:plot/store/store.dart';

/// Manages push notification token registration and message handling.
///
/// On mobile (iOS/Android), uses FCM for push delivery.
/// On desktop (macOS/Windows), uses WebSocket sync completions as the trigger.
///
/// Call [start] after sign-in and [stop] on sign-out.
class NotificationService with WidgetsBindingObserver, WindowListener {
  static final NotificationService _instance = NotificationService._();
  static NotificationService get instance => _instance;
  NotificationService._();

  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _messageOpenedSubscription;
  String? _currentToken;
  bool _started = false;

  /// Whether the token has been successfully registered with the API.
  bool _tokenRegistered = false;

  /// The current user's display name, sent to the notification summary API
  /// so the LLM avoids referring to the recipient by name.
  String? _userName;

  /// Whether the user denied notification permission.
  bool _permissionDenied = false;

  /// Retry state for token registration.
  int _retryCount = 0;
  Timer? _retryTimer;
  static const int _maxRetries = 5;
  static const Duration _baseRetryDelay = Duration(seconds: 2);

  /// Tracks notifications that have been shown: priorityId → notification id.
  /// Used for retraction when threads are read on another device.
  final Map<String, int> _shownNotifications = {};

  static const Duration _suppressionWindow = Duration(minutes: 5);

  /// Desktop: whether the app window is currently focused.
  bool _windowFocused = true;

  /// Desktop: debounce timer to prevent rapid-fire notifications from syncs.
  Timer? _desktopNotifyDebouncer;
  static const Duration _desktopNotifyDebounce = Duration(seconds: 2);

  /// Desktop: timer to retry notification display when quiet hours end.
  Timer? _quietHoursRetryTimer;

  /// Callback for navigating to a priority when a notification is tapped.
  void Function(String priorityId)? onNavigateToPriority;

  /// Whether push notifications are supported on this platform.
  static bool get isSupported =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid || Platform.isMacOS || Platform.isWindows);

  /// Whether the current platform uses FCM (mobile) vs WebSocket (desktop).
  static bool get _isMobile => !kIsWeb && (Platform.isIOS || Platform.isAndroid);
  static bool get _isDesktop => !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  /// Whether the user has denied notification permission.
  /// Check this to show a "re-enable" option in settings.
  bool get isPermissionDenied => _permissionDenied;

  /// Whether notifications are active. On mobile, this means the FCM token
  /// is registered. On desktop, this is true once the notification display
  /// is initialized (no token registration needed).
  bool get isTokenRegistered => _isDesktop ? _started : _tokenRegistered;

  /// Initialize notifications. On mobile, sets up Firebase Messaging and
  /// registers the device token. On desktop, listens for WebSocket sync
  /// completions. Call after sign-in.
  Future<void> start({required String userId, String? userName}) async {
    if (!isSupported) return;

    _started = true;
    _userName = userName;

    // Initialize local notification display
    try {
      await NotificationDisplay.instance.initialize();
      NotificationDisplay.instance.onNotificationTap = _handlePayloadTap;
    } catch (e) {
      log.warning('Failed to initialize notification display', e);
    }

    if (_isDesktop) {
      await _startDesktop();
    } else {
      await _startMobile(userId);
    }
  }

  /// Mobile: set up FCM, register token, and listen for push messages.
  Future<void> _startMobile(String userId) async {
    // Persist user ID and attention windows for background isolate access
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('notification_user_id', userId);
      await syncAttentionWindowsToPrefs(prefs);
    } catch (e) {
      log.warning('Failed to persist notification prefs', e);
    }

    // Register for app lifecycle events to re-register on resume
    WidgetsBinding.instance.addObserver(this);

    await _requestPermissionAndRegister();

    // Data message handler — triggers sync and local notification display
    _foregroundSubscription ??=
        FirebaseMessaging.onMessage.listen(_handleDataMessage);

    // Notification tap handler (app was in background)
    _messageOpenedSubscription ??=
        FirebaseMessaging.onMessageOpenedApp.listen((message) {
      log.info('Notification tapped: ${message.data}');
      _handleNotificationTap(message);
    });

    // Check if app was opened from a terminated state via notification
    try {
      final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
      if (initialMessage != null) {
        log.info('App opened from notification: ${initialMessage.data}');
        _handleNotificationTap(initialMessage);
      }
    } catch (e) {
      log.warning('Failed to get initial notification message', e);
    }
  }

  /// Desktop: listen for WebSocket sync completions and track window focus.
  Future<void> _startDesktop() async {
    // Track window focus state for notification suppression
    windowManager.addListener(this);
    try {
      _windowFocused = await windowManager.isFocused();
    } catch (_) {
      _windowFocused = true;
    }

    // Listen for sync completions from the WebSocket broadcast
    Store.get.onSyncBatchComplete = _handleDesktopSyncComplete;

    log.info('Desktop notification listener started');
  }

  /// Desktop: called when a WebSocket-triggered sync batch completes.
  void _handleDesktopSyncComplete(Set<String> entityNames) {
    // Only care about thread-related syncs
    if (!entityNames.contains('thread')) return;

    // Debounce to avoid rapid-fire notifications from frequent syncs
    _desktopNotifyDebouncer?.cancel();
    _desktopNotifyDebouncer = Timer(_desktopNotifyDebounce, () {
      _handleDesktopNotification();
    });
  }

  /// Desktop: check for unread threads and show notifications if unfocused.
  Future<void> _handleDesktopNotification() async {
    if (!_started) return;

    // Don't notify when the user is looking at the app
    if (_windowFocused) return;

    try {
      final store = Store.get;
      final batches = await _buildNotificationBatches(store);

      await _retractStaleNotifications(batches);

      if (batches.isEmpty) return;

      // Check quiet hours — if active, schedule a retry when they end
      final prefs = await SharedPreferences.getInstance();
      final scheduleAt = computeNotifyTime(prefs);
      if (scheduleAt != null) {
        final delay = scheduleAt.difference(DateTime.now());
        if (delay > Duration.zero) {
          _quietHoursRetryTimer?.cancel();
          _quietHoursRetryTimer = Timer(delay, () {
            _handleDesktopNotification();
          });
        }
        return;
      }

      // Check multi-device suppression, then show
      await _checkAndShowNotifications(batches, store);
    } catch (e) {
      log.warning('Error handling desktop notification', e);
    }
  }

  @override
  void onWindowFocus() {
    _windowFocused = true;
    // User is back — cancel all notifications since they can see the app
    NotificationDisplay.instance.cancelAll();
    _shownNotifications.clear();
    _quietHoursRetryTimer?.cancel();
    _quietHoursRetryTimer = null;
  }

  @override
  void onWindowBlur() {
    _windowFocused = false;
  }

  /// Request permission and register the FCM token.
  /// Called on start and can be re-called to retry after permission denial.
  Future<void> _requestPermissionAndRegister() async {
    final messaging = FirebaseMessaging.instance;

    // Check current permission status first (doesn't prompt)
    final currentSettings = await messaging.getNotificationSettings();
    log.info('Push notification permission: ${currentSettings.authorizationStatus}');

    if (currentSettings.authorizationStatus == AuthorizationStatus.denied) {
      // On Android, denied means explicitly denied — requestPermission won't
      // re-prompt. On iOS, it means not yet decided or denied.
      if (Platform.isAndroid) {
        _permissionDenied = true;
        log.info('Push notifications denied — user must enable in system settings');
        return;
      }
    }

    if (currentSettings.authorizationStatus == AuthorizationStatus.notDetermined) {
      // First time — show the permission dialog
      try {
        final settings = await messaging.requestPermission();
        if (settings.authorizationStatus == AuthorizationStatus.denied) {
          _permissionDenied = true;
          log.info('Push notification permission denied by user');
          return;
        }
      } catch (e) {
        log.warning('Failed to request notification permission', e);
        return;
      }
    }

    _permissionDenied = false;

    // Get current token and register
    await _getTokenAndRegister();

    // Listen for token refresh
    _tokenRefreshSubscription ??=
        messaging.onTokenRefresh.listen((token) async {
      _currentToken = token;
      try {
        await _registerToken(token);
        _tokenRegistered = true;
        _retryCount = 0;
      } catch (e) {
        log.warning('Failed to register refreshed FCM token', e);
        _scheduleRetry();
      }
    });
  }

  /// Get the FCM token and register it with the API, with retry on failure.
  Future<void> _getTokenAndRegister() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        _currentToken = token;
        log.info('FCM token obtained, registering...');
        await _registerToken(token);
        _tokenRegistered = true;
        _retryCount = 0;
        log.info('Device token registered successfully');
      } else {
        log.warning('FCM getToken() returned null — will retry');
        Tracker.trackError(
          'notification',
          errorType: 'FCMTokenNull',
          errorMessage: 'FirebaseMessaging.getToken() returned null',
          context: 'push_token_acquisition',
        );
        _scheduleRetry();
      }
    } catch (e) {
      log.warning('Failed to get/register FCM token', e);
      Tracker.trackError(
        'notification',
        errorType: e.runtimeType.toString(),
        errorMessage: e.toString(),
        context: 'push_token_registration',
      );
      _scheduleRetry();
    }
  }

  /// Schedule a retry with exponential backoff and jitter.
  void _scheduleRetry() {
    if (_retryCount >= _maxRetries) {
      log.warning('FCM token registration failed after $_maxRetries retries');
      Tracker.trackError(
        'notification',
        errorType: 'FCMRegistrationFailed',
        errorMessage: 'Token registration failed after $_maxRetries retries',
        context: 'push_token_registration',
      );
      return;
    }

    _retryTimer?.cancel();
    _retryCount++;
    final delayMs = _baseRetryDelay.inMilliseconds * pow(2, _retryCount - 1).toInt();
    final jitter = Random().nextInt(delayMs ~/ 2);
    final delay = Duration(milliseconds: delayMs + jitter);

    log.info('Scheduling FCM registration retry $_retryCount/$_maxRetries in ${delay.inSeconds}s');

    _retryTimer = Timer(delay, () async {
      if (!_started) return;
      await _getTokenAndRegister();
    });
  }

  /// Re-register on app resume (mobile only). Handles cases where:
  /// - Initial registration failed (network was down at startup)
  /// - Token became stale while app was backgrounded
  /// - User granted permission in system settings after previously denying
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isMobile) return;
    if (state != AppLifecycleState.resumed || !_started) return;

    // If permission was previously denied, re-check — user may have
    // enabled notifications in system settings
    if (_permissionDenied) {
      _recheckPermission();
      return;
    }

    // If token was never registered, try again
    if (!_tokenRegistered) {
      _retryCount = 0; // Reset retries on resume
      _getTokenAndRegister();
    }
  }

  /// Re-check permission status after returning from system settings.
  Future<void> _recheckPermission() async {
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      if (settings.authorizationStatus != AuthorizationStatus.denied) {
        log.info('Notification permission now granted — registering token');
        _permissionDenied = false;
        _retryCount = 0;
        await _requestPermissionAndRegister();
      }
    } catch (e) {
      log.warning('Failed to re-check notification permission', e);
    }
  }

  /// Re-request notification permission and register.
  /// Call from settings UI when user wants to enable notifications.
  Future<NotificationPermissionResult> requestPermission() async {
    if (!isSupported) return NotificationPermissionResult.unsupported;

    if (_isDesktop) {
      // Desktop: re-initialize the notification display which will
      // re-request permission on macOS. Windows doesn't need permission.
      try {
        await NotificationDisplay.instance.initialize();
        _permissionDenied = false;
        return NotificationPermissionResult.granted;
      } catch (e) {
        log.warning('Failed to initialize desktop notifications', e);
        return NotificationPermissionResult.error;
      }
    }

    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.getNotificationSettings();

    if (settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional) {
      // Already authorized — just ensure token is registered
      _permissionDenied = false;
      if (!_tokenRegistered) {
        _retryCount = 0;
        await _getTokenAndRegister();
      }
      return NotificationPermissionResult.granted;
    }

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      // On Android, once denied, the OS won't show the dialog again.
      // User must go to system settings.
      if (Platform.isAndroid) {
        return NotificationPermissionResult.deniedPermanently;
      }
    }

    // Try requesting (works on iOS for notDetermined, or Android first-time)
    try {
      final result = await messaging.requestPermission();
      if (result.authorizationStatus == AuthorizationStatus.denied) {
        _permissionDenied = true;
        return NotificationPermissionResult.denied;
      }

      _permissionDenied = false;
      _retryCount = 0;
      await _getTokenAndRegister();
      return NotificationPermissionResult.granted;
    } catch (e) {
      log.warning('Failed to request notification permission', e);
      return NotificationPermissionResult.error;
    }
  }

  /// Deregister the device token and clean up listeners.
  /// Call on sign-out.
  Future<void> stop() async {
    if (!isSupported) return;

    _started = false;
    _permissionDenied = false;

    // Cancel shown notifications
    await NotificationDisplay.instance.cancelAll();
    _shownNotifications.clear();

    if (_isDesktop) {
      await _stopDesktop();
    } else {
      await _stopMobile();
    }
  }

  Future<void> _stopMobile() async {
    _tokenRegistered = false;
    _retryCount = 0;
    _retryTimer?.cancel();
    _retryTimer = null;

    WidgetsBinding.instance.removeObserver(this);

    // Remove persisted user ID so background handler won't fire
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('notification_user_id');
    } catch (e) {
      log.warning('Failed to remove notification user ID', e);
    }

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

  Future<void> _stopDesktop() async {
    _desktopNotifyDebouncer?.cancel();
    _desktopNotifyDebouncer = null;
    _quietHoursRetryTimer?.cancel();
    _quietHoursRetryTimer = null;
    windowManager.removeListener(this);
    _windowFocused = true;

    // Clear the sync callback
    try {
      Store.get.onSyncBatchComplete = null;
    } catch (_) {
      // Store may already be closed
    }
  }

  Future<void> _registerToken(String token) async {
    final platform = Platform.isIOS ? 'ios' : 'android';
    await api.put<Map<String, dynamic>>('/device', body: {
      'platform': platform,
      'pushToken': token,
      'appVersion': '${AppInfo.version}+${AppInfo.buildNumber}',
    });
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
          'user_name': _userName,
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
    final shown = await showSummaryNotifications(summaries);
    _shownNotifications.addAll(shown);
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
    if (_isDesktop) {
      // Bring the window to front when a notification is tapped
      windowManager.show();
      windowManager.focus();
    }
    if (payload != null && payload.isNotEmpty) {
      onNavigateToPriority?.call(payload);
    }
  }
}

/// Result of requesting notification permission.
enum NotificationPermissionResult {
  /// Permission granted — token is being registered.
  granted,

  /// User denied the permission dialog.
  denied,

  /// User previously denied and must enable in system settings (Android).
  deniedPermanently,

  /// Platform doesn't support push notifications.
  unsupported,

  /// An error occurred during the request.
  error,
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

/// Sync the root priority's attention windows to SharedPreferences so the
/// background isolate can check quiet hours without Drift access.
///
/// Uses the root priority's attention_window if explicitly set, otherwise
/// leaves the key absent (background handler falls back to default quiet hours).
Future<void> syncAttentionWindowsToPrefs([SharedPreferences? prefs]) async {
  try {
    prefs ??= await SharedPreferences.getInstance();
    final store = Store.get;

    // Find any priority with attention_window explicitly set
    final priorities = await (store.select(store.priorities)
          ..where((t) => t.attentionWindowSet.equals(true)))
        .get();

    // Use the first explicitly-set attention window found
    final window = priorities
        .where((p) => p.attentionWindow != null)
        .map((p) => p.attentionWindow!)
        .firstOrNull;

    if (window != null) {
      await prefs.setString('attention_windows', window);
    } else {
      await prefs.remove('attention_windows');
    }
  } catch (e) {
    log.warning('Failed to sync attention windows to prefs', e);
  }
}

/// Show local notifications from a list of API summary objects.
///
/// Each summary map must have: `title`, `body`, `target_priority_id`, and
/// optionally `urgency`. Returns a map of targetPriorityId → notification id
/// for all notifications shown.
///
/// This function is package-level so it can be called from both
/// [NotificationService] (foreground) and the background handler.
Future<Map<String, int>> showSummaryNotifications(
  List<Map<String, dynamic>> summaries,
) async {
  final shown = <String, int>{};
  for (var i = 0; i < summaries.length; i++) {
    final summary = summaries[i];
    final title = summary['title'] as String? ?? 'Updates';
    final body = summary['body'] as String? ?? 'You have new updates';
    final targetPriorityId = summary['target_priority_id'] as String? ?? '';
    final urgency = summary['urgency'] as String?;

    await NotificationDisplay.instance.showBatchNotification(
      id: i,
      title: title,
      body: body,
      targetPriorityId: targetPriorityId,
      urgency: urgency ?? 'inform-updates',
    );
    if (targetPriorityId.isNotEmpty) {
      shown[targetPriorityId] = i;
    }
  }
  return shown;
}

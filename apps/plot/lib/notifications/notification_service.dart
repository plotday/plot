import 'dart:async';
import 'dart:convert';
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
import 'package:plot/notifications/notification_window.dart';
import 'package:plot/store/attention.dart';
import 'package:plot/store/store.dart';

/// Notification ID and SharedPreferences key for the "Plot signed out" push
/// that the background FCM handler displays when Clerk reports the session
/// invalid. Kept at file scope so both the main app and the background
/// isolate (in `background_handler.dart`) reference the same values.
const int _signedOutNotificationId = 999900;
const String _lastSignedOutNotifyKey = 'last_signed_out_notify_ms';

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

  /// Tracks notifications that have been shown: priorityId → (id, threadIds).
  /// Used for retraction and dedup when threads are read on another device.
  final Map<String, ({int id, Set<String> threadIds})> _shownNotifications = {};

  static const Duration _suppressionWindow = Duration(minutes: 5);

  /// Desktop: whether the app window is currently focused.
  bool _windowFocused = true;

  /// Desktop: debounce timer to prevent rapid-fire notifications from syncs.
  Timer? _desktopNotifyDebouncer;
  static const Duration _desktopNotifyDebounce = Duration(seconds: 2);

  /// Desktop: timer to retry notification display when quiet hours end.
  Timer? _quietHoursRetryTimer;

  /// Callback for navigating to a notification target when tapped. The
  /// target carries the priority id plus the thread ids covered by the
  /// notification, so the router can open a single thread directly when
  /// only one is new. Setting this replays any buffered cold-start payload.
  void Function(NotificationTapTarget target)? _onNavigate;

  /// Pending payload from a notification tap that arrived before the router
  /// was ready (cold start). Replayed when [onNavigate] is set.
  NotificationTapTarget? _pendingNavigationTarget;

  set onNavigate(void Function(NotificationTapTarget target)? callback) {
    _onNavigate = callback;
    if (callback != null && _pendingNavigationTarget != null) {
      final target = _pendingNavigationTarget!;
      _pendingNavigationTarget = null;
      log.info(
        'Replaying buffered notification target: '
        'priority=${target.priorityId} threads=${target.threadIds.length}',
      );
      callback(target);
    }
  }

  void Function(NotificationTapTarget target)? get onNavigate => _onNavigate;

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
  /// is initialized and permission has been granted.
  bool get isTokenRegistered => _isDesktop ? _started && !_permissionDenied : _tokenRegistered;

  /// Initialize notifications. On mobile, sets up Firebase Messaging and
  /// registers the device token. On desktop, listens for WebSocket sync
  /// completions. Call after sign-in.
  Future<void> start({required String userId, String? userName}) async {
    if (!isSupported) return;

    _started = true;
    _userName = userName;

    // Initialize local notification display.
    // Set onNotificationTap BEFORE initialize() so foreground taps work.
    try {
      NotificationDisplay.instance.onNotificationTap = _handlePayloadTap;
      await NotificationDisplay.instance.initialize();

      // Check if the app was launched by tapping a local notification (cold start).
      // The plugin doesn't fire onNotificationTap for this case — it stores the
      // launch details for explicit retrieval.
      final launchDetails = await NotificationDisplay.instance.getLaunchNotification();
      if (launchDetails != null) {
        log.info('App launched from notification tap: $launchDetails');
        _handlePayloadTap(launchDetails);
      }
    } catch (e) {
      log.warning('Failed to initialize notification display', e);
    }

    // Load persisted thread IDs from a previous session/background handler
    await _loadPersistedThreadIds();

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
      await syncNotifyWindowsToPrefs(prefs);
      // Clear any stale "Plot signed out" notification the background handler
      // may have shown while the session was dead, and reset the cooldown so
      // the next real expiry can notify again.
      await NotificationDisplay.instance.cancel(_signedOutNotificationId);
      await prefs.remove(_lastSignedOutNotifyKey);
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

    // Check macOS notification permission on startup
    if (Platform.isMacOS) {
      final settings = await NotificationDisplay.instance.getNotificationSettings();
      final isEnabled = settings?['enabled'] == 'true';
      _permissionDenied = !isEnabled;
      log.info('macOS notification permission: enabled=$isEnabled');
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

      // Check the notify window — if currently closed, schedule a retry
      // for when it opens. Urgent threads bypass the window.
      //
      // Smart deferral: when at least one batch's first-level priority
      // has an upcoming focus block, the earliest such block becomes
      // the delivery deadline — we pick the latest notify-window opening
      // on or before it instead of falling back to "the very next
      // opening". When no batch has a focus block, the legacy fallback
      // ([computeWindowOpenTime]) is used.
      final prefs = await SharedPreferences.getInstance();
      final hasUrgent = batches.any((b) => b.highestUrgent);
      if (!hasUrgent) {
        final now = DateTime.now();
        DateTime? earliestDeadline;
        for (final batch in batches) {
          final priorityIdStr = batch.firstLevelPriorityId;
          PriorityId pid;
          try {
            pid = Uuid.fromString(priorityIdStr);
          } catch (_) {
            continue;
          }
          final fb = await PriorityBlock.nextFocusBlockStart(
            priorityId: pid,
            after: now,
          );
          if (fb == null) continue;
          if (earliestDeadline == null || fb.isBefore(earliestDeadline)) {
            earliestDeadline = fb;
          }
        }
        final scheduleAt = earliestDeadline != null
            ? computeSmartDeliveryAt(prefs, earliestDeadline, now: now)
            : computeWindowOpenTime(prefs, now: now);
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
    _clearPersistedThreadIds();
    _quietHoursRetryTimer?.cancel();
    _quietHoursRetryTimer = null;
    // Flutter's AppLifecycleState doesn't fire `resumed`/`inactive` on
    // desktop window focus changes, so propagate focus → active manually.
    BroadcastClient.instance.setActive(true);
  }

  @override
  void onWindowBlur() {
    _windowFocused = false;
    BroadcastClient.instance.setActive(false);
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

    // Subscribe to token refresh BEFORE the initial getToken() attempt. On
    // iOS the first FCM token is delivered via this stream once APNS is
    // ready, so subscribing first avoids missing it if APNS arrives between
    // our wait loop and the listener being set up.
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

    await _getTokenAndRegister();
  }

  /// Get the FCM token and register it with the API, with retry on failure.
  Future<void> _getTokenAndRegister() async {
    // On iOS, getToken() throws `[firebase_messaging/apns-token-not-set]` if
    // called before APNS has delivered the device token. Poll getAPNSToken()
    // first so we don't burn retries on a transient startup race that every
    // retry will hit identically.
    if (Platform.isIOS && !await _waitForApnsToken()) {
      // APNS hasn't arrived yet. Don't treat this as an error or schedule
      // our own retry — onTokenRefresh will fire when APNS eventually lands,
      // and app resume re-enters this method.
      log.info('APNS token not yet available — deferring FCM registration');
      return;
    }

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

  /// iOS only: poll `getAPNSToken()` until it returns non-null or we time
  /// out. Firebase's `getToken()` throws `apns-token-not-set` if called
  /// before iOS has handed us the APNS device token — typically a few
  /// seconds after permission is granted, but can be longer on cold start
  /// or poor networks.
  Future<bool> _waitForApnsToken() async {
    const interval = Duration(milliseconds: 500);
    const maxAttempts = 20; // 10s total
    final messaging = FirebaseMessaging.instance;
    for (int i = 0; i < maxAttempts; i++) {
      try {
        if (await messaging.getAPNSToken() != null) return true;
      } catch (e) {
        log.warning('getAPNSToken() failed', e);
        return false;
      }
      if (i < maxAttempts - 1) {
        await Future<void>.delayed(interval);
      }
    }
    return false;
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
      try {
        await NotificationDisplay.instance.initialize();
        if (Platform.isMacOS) {
          // Check current permission state
          final settings = await NotificationDisplay.instance.getNotificationSettings();
          final isEnabled = settings?['enabled'] == 'true';
          if (isEnabled) {
            _permissionDenied = false;
            return NotificationPermissionResult.granted;
          }
          // Try requesting — this only works if status is notDetermined
          final granted = await NotificationDisplay.instance.requestMacOSPermission();
          if (granted) {
            _permissionDenied = false;
            return NotificationPermissionResult.granted;
          }
          // macOS won't re-prompt — user must go to System Settings
          _permissionDenied = true;
          return NotificationPermissionResult.deniedPermanently;
        }
        // Windows doesn't need permission
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
    _clearPersistedThreadIds();

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
        await NotificationDisplay.instance.cancel(entry.value.id);
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
      // Threads below the importance gate stay in-app only unless flagged
      // urgent (urgent bypasses the gate).
      final isUrgent = thread.urgent ?? false;
      if (!isUrgent && thread.importance < 50) continue;

      final priorityIdStr = thread.priorityId.value.toString();
      final priority = priorityById[priorityIdStr];
      if (priority == null) continue;

      // Find the first-level priority (direct child of root)
      final firstLevel = _findFirstLevelPriority(
        priority.path.value, rootPath, allPriorities,
      );
      if (firstLevel == null) continue;

      // Filter out stale threads already cleared at the focus level. The
      // high-water mark lives on the first-level focus (matching how the
      // server stamps it and how opening a focus clears it), so read it from
      // the focus, not the leaf priority.
      final clearedAt = firstLevel.notificationClearedAt;
      if (clearedAt != null && !thread.updatedAt.isAfter(clearedAt)) {
        continue;
      }

      final firstLevelIdStr = firstLevel.id.value.toString();

      final batch = batchMap.putIfAbsent(
        firstLevelIdStr,
        () => NotificationBatch(
          firstLevelPriorityId: firstLevelIdStr,
          priorityTitle: firstLevel.title,
          threads: [],
          highestUrgent: false,
          notifyWindow: firstLevel.notifyWindow != null
              ? AttentionWindow.fromJsonString(firstLevel.notifyWindow)
              : null,
          targetPriorityId: firstLevelIdStr, // Always route directly to the focus
        ),
      );

      batch.threads.add(NotificationThread(
        id: thread.id.value.toString(),
        title: thread.title,
        preview: thread.preview,
        urgent: isUrgent,
        priorityId: priorityIdStr,
      ));

      // Track whether any thread in this batch is urgent.
      if (isUrgent) batch.highestUrgent = true;
    }

    // Clean up empty batches (e.g. if all threads were filtered out)
    batchMap.removeWhere((_, batch) => batch.threads.isEmpty);

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
  /// Skips re-showing if the thread set for a priority is unchanged.
  Future<void> _showNotifications(List<Map<String, dynamic>> summaries) async {
    final shown = await showSummaryNotifications(
      summaries,
      previousThreadIds: _shownNotifications.map(
        (k, v) => MapEntry(k, v.threadIds),
      ),
    );
    _shownNotifications.addAll(shown);
    _persistThreadIds();
  }

  /// Fallback: show simple notifications without AI summary.
  Future<void> _showFallbackNotifications(List<NotificationBatch> batches) async {
    for (final batch in batches) {
      final title = batch.priorityTitle ?? 'Updates';
      final body = batch.threads.length == 1
          ? batch.threads.first.title ?? 'New update'
          : '${batch.threads.length} new updates';

      final displayId = batch.targetPriorityId ?? batch.firstLevelPriorityId;
      final notifId = _stableNotificationId(displayId);
      final orderedThreadIds = batch.threads.map((t) => t.id).toList();
      final newThreadIds = orderedThreadIds.toSet();

      // Skip if thread set is unchanged
      final previous = _shownNotifications[displayId];
      if (previous != null && _setsEqual(previous.threadIds, newThreadIds)) {
        continue;
      }

      await NotificationDisplay.instance.showBatchNotification(
        id: notifId,
        title: title,
        body: body,
        targetPriorityId: NotificationTapTarget(
          priorityId: displayId,
          threadIds: orderedThreadIds,
        ).encode(),
        urgent: batch.highestUrgent,
      );
      _shownNotifications[displayId] = (id: notifId, threadIds: newThreadIds);
    }
    _persistThreadIds();
  }

  /// Derive a stable notification ID from a priority ID string.
  static int _stableNotificationId(String priorityId) =>
      priorityId.hashCode.abs() % 100000;

  /// Compare two sets for equality.
  static bool _setsEqual(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  /// Persist the current thread ID sets to SharedPreferences so the background
  /// isolate can also deduplicate.
  Future<void> _persistThreadIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = _shownNotifications.map(
        (k, v) => MapEntry(k, v.threadIds.toList()..sort()),
      );
      await prefs.setString('notification_thread_ids', jsonEncode(data));
    } catch (e) {
      log.warning('Failed to persist notification thread IDs', e);
    }
  }

  /// Clear persisted thread IDs (on sign-out or when all notifications are dismissed).
  Future<void> _clearPersistedThreadIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('notification_thread_ids');
    } catch (e) {
      log.warning('Failed to clear persisted notification thread IDs', e);
    }
  }

  /// Load persisted thread IDs into the in-memory map on startup.
  Future<void> _loadPersistedThreadIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('notification_thread_ids');
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in data.entries) {
        final threadIds = (entry.value as List).cast<String>().toSet();
        _shownNotifications[entry.key] = (
          id: _stableNotificationId(entry.key),
          threadIds: threadIds,
        );
      }
    } catch (e) {
      log.warning('Failed to load persisted notification thread IDs', e);
    }
  }

  void _handleNotificationTap(RemoteMessage message) {
    final targetPriorityId = message.data['target_priority_id'] as String?;
    if (targetPriorityId == null || targetPriorityId.isEmpty) return;
    final threadIdsRaw = message.data['thread_ids'];
    final threadIds = threadIdsRaw is String && threadIdsRaw.isNotEmpty
        ? threadIdsRaw.split(',').where((s) => s.isNotEmpty).toList()
        : const <String>[];
    _dispatchTap(
      NotificationTapTarget(priorityId: targetPriorityId, threadIds: threadIds),
    );
  }

  void _handlePayloadTap(String? payload) {
    if (_isDesktop) {
      // Bring the window to front when a notification is tapped
      windowManager.show();
      windowManager.focus();
    }
    final target = NotificationTapTarget.decode(payload);
    if (target == null) return;
    _dispatchTap(target);
  }

  void _dispatchTap(NotificationTapTarget target) {
    if (_onNavigate != null) {
      _onNavigate!(target);
    } else {
      // Router not ready yet (cold start) — buffer for replay
      log.info(
        'Buffering notification target: priority=${target.priorityId} '
        'threads=${target.threadIds.length}',
      );
      _pendingNavigationTarget = target;
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
  bool highestUrgent;
  String? targetPriorityId;
  final List<AttentionWindow>? notifyWindow;

  NotificationBatch({
    required this.firstLevelPriorityId,
    required this.priorityTitle,
    required this.threads,
    required this.highestUrgent,
    this.targetPriorityId,
    this.notifyWindow,
  });
}

/// A single unread thread within a notification batch.
class NotificationThread {
  final String id;
  final String? title;
  final String? preview;
  final bool urgent;
  final String priorityId;

  NotificationThread({
    required this.id,
    required this.title,
    required this.preview,
    required this.urgent,
    required this.priorityId,
  });
}

/// Sync the root priority's `notify_window` to SharedPreferences so the
/// background isolate can check whether the user wants early notifications
/// right now without Drift access.
///
/// Uses the root priority's `notify_window` if explicitly set, otherwise
/// leaves the key absent so [computeWindowOpenTime] falls back to its
/// always-open default.
Future<void> syncNotifyWindowsToPrefs([SharedPreferences? prefs]) async {
  try {
    prefs ??= await SharedPreferences.getInstance();
    final store = Store.get;

    // Prefer the root priority's `notify_window` (its inherited resolved
    // value), and fall back to any explicit override if root isn't loaded.
    final rootRows = await (store.select(store.priorities)
          ..where((t) => t.root.equals(true))
          ..limit(1))
        .get();
    String? window = rootRows.firstOrNull?.notifyWindow;
    if (window == null) {
      final overrides = await (store.select(store.priorities)
            ..where((t) => t.notifyWindowSet.equals(true)))
          .get();
      window = overrides
          .where((p) => p.notifyWindow != null)
          .map((p) => p.notifyWindow!)
          .firstOrNull;
    }

    if (window != null) {
      await prefs.setString(notifyWindowsPrefsKey, window);
    } else {
      await prefs.remove(notifyWindowsPrefsKey);
    }
  } catch (e) {
    log.warning('Failed to sync notify windows to prefs', e);
  }
}

/// Show local notifications from a list of API summary objects.
///
/// Each summary map must have: `title`, `body`, `target_priority_id`, and
/// optionally `urgency` and `thread_ids`. Returns a map of
/// targetPriorityId → (id, threadIds) for all notifications shown.
///
/// If [previousThreadIds] is provided, notifications whose thread set is
/// unchanged are silently skipped (no vibration, no AI call wasted).
///
/// This function is package-level so it can be called from both
/// [NotificationService] (foreground) and the background handler.
Future<Map<String, ({int id, Set<String> threadIds})>> showSummaryNotifications(
  List<Map<String, dynamic>> summaries, {
  Map<String, Set<String>>? previousThreadIds,
}) async {
  final shown = <String, ({int id, Set<String> threadIds})>{};
  for (final summary in summaries) {
    final title = summary['title'] as String? ?? 'Updates';
    final body = summary['body'] as String? ?? 'You have new updates';
    final targetPriorityId = summary['target_priority_id'] as String? ?? '';
    final urgent = summary['urgent'] as bool? ?? false;
    final orderedThreadIds =
        (summary['thread_ids'] as List?)?.cast<String>() ?? const <String>[];
    final threadIds = orderedThreadIds.toSet();
    final notifId = targetPriorityId.hashCode.abs() % 100000;

    // Skip if thread set is unchanged
    if (previousThreadIds != null && threadIds.isNotEmpty) {
      final prev = previousThreadIds[targetPriorityId];
      if (prev != null &&
          prev.length == threadIds.length &&
          prev.containsAll(threadIds)) {
        continue;
      }
    }

    await NotificationDisplay.instance.showBatchNotification(
      id: notifId,
      title: title,
      body: body,
      targetPriorityId: NotificationTapTarget(
        priorityId: targetPriorityId,
        threadIds: orderedThreadIds,
      ).encode(),
      urgent: urgent,
    );
    if (targetPriorityId.isNotEmpty) {
      shown[targetPriorityId] = (id: notifId, threadIds: threadIds);
    }
  }
  return shown;
}

/// Decoded target carried by a notification payload (and `data.thread_ids`
/// on direct FCM taps). Encodes as `priorityId|threadId,threadId,...` so
/// the priority-only legacy format (`priorityId`) decodes seamlessly.
class NotificationTapTarget {
  NotificationTapTarget({required this.priorityId, this.threadIds = const []});

  final String priorityId;
  final List<String> threadIds;

  String encode() {
    if (threadIds.isEmpty) return priorityId;
    return '$priorityId|${threadIds.join(',')}';
  }

  static NotificationTapTarget? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    final pipe = payload.indexOf('|');
    if (pipe < 0) {
      return NotificationTapTarget(priorityId: payload);
    }
    final priorityId = payload.substring(0, pipe);
    if (priorityId.isEmpty) return null;
    final rest = payload.substring(pipe + 1);
    final threads = rest.isEmpty
        ? const <String>[]
        : rest.split(',').where((s) => s.isNotEmpty).toList();
    return NotificationTapTarget(priorityId: priorityId, threadIds: threads);
  }
}

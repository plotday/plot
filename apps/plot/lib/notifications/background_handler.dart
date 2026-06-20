import 'dart:convert';
import 'dart:io';

import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/auth/auth_service_interface.dart';
import 'package:plot/auth/clerk_session_ops.dart';
import 'package:plot/auth/session_token_resolver.dart';
import 'package:plot/notifications/notification_display.dart';
import 'package:plot/notifications/notification_window.dart';
import 'package:plot/notifications/notification_service.dart';

const _threadIdsPrefsKey = 'notification_thread_ids';
// Must stay in sync with the copies in notification_service.dart — the main
// app cancels this notification and clears this pref key when it signs in.
const _lastSignedOutNotifyKey = 'last_signed_out_notify_ms';
const _signedOutNotificationId = 999900;
const _signedOutNotifyCooldown = Duration(hours: 24);
// Breadcrumb written when the background isolate concludes the session is
// CONFIRMED invalid (server-reconciled). The main app reads it on next
// sign-in and forwards it to PostHog — the background isolate has no tracker
// of its own. Must stay in sync with the copy in notification_service.dart.
const _bgSessionInvalidAtKey = 'bg_session_invalid_at_ms';

/// Stable local notification ID reserved for OTP/confirm pushes.
/// Distinct from the priority-hash range (0–99999) and the signed-out ID
/// (999900). A newer OTP/confirm replaces any prior one via replace-by-id.
const _otpNotificationId = 999901;

/// Debug-only logger for the background isolate.
///
/// Gated on [kDebugMode] so release builds never write user, thread, or note
/// identifiers to the device console. Uses [debugPrint] (allowed by the
/// `avoid_print` lint) instead of `print`.
void _bgLog(String message) {
  if (kDebugMode) {
    debugPrint('[BG_HANDLER] $message');
  }
}

/// Top-level background message handler registered with Firebase Messaging.
///
/// Runs in a separate isolate when the app is backgrounded or terminated.
/// Fetches fresh notification content from the API and shows (or schedules)
/// a local notification.
@pragma('vm:entry-point')
Future<void> handleBackgroundMessage(RemoteMessage message) async {
  _bgLog('message received type=${message.data['type']}');

  final type = message.data['type'] as String?;

  // OTP/confirm push: time-sensitive — show an OS notification immediately,
  // bypassing the notify-window defer entirely.
  if (type == 'otp') {
    await _handleOtpBackgroundMessage(message);
    return;
  }

  if (type != 'sync_wake') return;

  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final apiRoot = prefs.getString('api_root');
  final publishableKey = prefs.getString('clerk_publishable_key');
  final userId = prefs.getString('notification_user_id');
  _bgLog('prefs: apiRoot=$apiRoot userId=$userId publishableKey=${publishableKey != null}');
  if (apiRoot == null || publishableKey == null || userId == null) {
    _bgLog('missing prefs — aborting');
    return;
  }

  // Obtain a fresh session token using Clerk's persisted cache.
  _bgLog('getting session token...');
  final tokenResult = await _getSessionToken(publishableKey);
  final token = tokenResult.token;
  _bgLog('token=${token != null ? 'ok' : 'null'} failure=${tokenResult.failure}');
  if (token == null) {
    // Only alarm the user when the session is *confirmed* dead. A transient
    // failure (no network, a slow Doze-mode cold start that times out
    // `initialize()`, or an unreachable server) must NOT show the "Plot
    // signed out" notification — the foreground app is almost certainly still
    // signed in, so we'd just be crying wolf. Prod incident: overnight network
    // outages fired this notification while Clerk's server logs showed the
    // session was never revoked. See [resolveSessionToken].
    if (tokenResult.failure == TokenFailureReason.sessionInvalid) {
      await _recordBackgroundSessionInvalid(prefs);
      await _maybeShowSignedOutNotification(prefs);
    } else {
      _bgLog('token unavailable (transient: ${tokenResult.failure}) — '
          'suppressing signed-out notification');
    }
    return;
  }

  // Fetch up-to-date notification summaries from the API
  _bgLog('fetching notification content from $apiRoot...');
  final summaries = await _fetchNotificationContent(apiRoot, token);
  _bgLog('summaries=${summaries?.length ?? 'null'}');
  if (summaries == null || summaries.isEmpty) return;

  // Initialize local notification display
  await NotificationDisplay.instance.initialize();

  // Load previously shown thread IDs for dedup
  final previousThreadIds = _loadPersistedThreadIds(prefs);

  // Check whether the notify window is open right now. If it's closed and
  // none of the summaries are flagged urgent, defer delivery until the
  // next opening. Urgent notifications bypass the window.
  final hasUrgent = summaries.any((s) => (s['urgent'] as bool?) ?? false);
  final scheduleAt = hasUrgent ? null : computeWindowOpenTime(prefs);
  _bgLog('scheduleAt=$scheduleAt (urgent=$hasUrgent)');
  if (scheduleAt != null) {
    // Notify window closed: schedule persistent notifications for when it opens.
    await _scheduleNotifications(summaries, scheduleAt);
  } else {
    final shown = await showSummaryNotifications(
      summaries,
      previousThreadIds: previousThreadIds,
    );
    await _persistThreadIds(prefs, shown);
  }
}

/// Handle a background `type:"otp"` push.
///
/// Shows a local OS notification IMMEDIATELY — bypasses the notify-window
/// defer because OTP codes and confirm links are time-sensitive (a code
/// expires in minutes). Uses a single stable ID ([_otpNotificationId]) so
/// a newer push replaces any prior one.
///
/// CTA content is fetched from the server using the noteId carried in the
/// push data. If the fetch fails or returns no cta, falls back to a generic
/// "Verification message" notification that deep-links to the thread.
Future<void> _handleOtpBackgroundMessage(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();

  final noteId = message.data['noteId'] as String?;
  final threadId = message.data['threadId'] as String?;
  final kind = message.data['kind'] as String?;

  final prefs = await SharedPreferences.getInstance();
  final apiRoot = prefs.getString('api_root');
  final publishableKey = prefs.getString('clerk_publishable_key');

  _bgLog('otp: noteId=$noteId threadId=$threadId kind=$kind');

  await NotificationDisplay.instance.initialize();

  // The deep-link payload: route tap to the thread (or just open the app if
  // threadId is missing). Uses the same NotificationTapTarget encoding as
  // other notifications so the router handles it correctly.
  final tapPayload = threadId != null && threadId.isNotEmpty
      ? NotificationTapTarget(
          priorityId: threadId,
          threadIds: [threadId],
        ).encode()
      : '';

  // Try to fetch the cta for rich notification content.
  _OtpContent? otp;
  if (noteId != null && apiRoot != null && publishableKey != null) {
    final token = (await _getSessionToken(publishableKey)).token;
    if (token != null) {
      otp = await _fetchOtpContent(apiRoot, token, noteId);
    }
  }

  if (otp != null) {
    final isOtpKind =
        (otp.kind == 'otp' || kind == 'otp') &&
        otp.code != null &&
        otp.code!.isNotEmpty;
    final service = otp.service.isNotEmpty ? otp.service : 'Verification';
    final title = isOtpKind ? service : 'Confirm your $service account';
    final body = isOtpKind ? 'Code: ${otp.code}' : 'Tap to confirm your account';
    _bgLog('otp: showing rich notification isOtp=$isOtpKind service=$service');
    await NotificationDisplay.instance.showBatchNotification(
      id: _otpNotificationId,
      title: title,
      body: body,
      targetPriorityId: tapPayload,
      urgent: true,
    );
  } else {
    // Fallback: generic notification so the user knows to check the app.
    _bgLog('otp: cta unavailable, showing fallback notification');
    await NotificationDisplay.instance.showBatchNotification(
      id: _otpNotificationId,
      title: 'Verification message',
      body: 'You have a new verification message',
      targetPriorityId: tapPayload,
      urgent: true,
    );
  }
}

/// Parsed CTA content returned by [_fetchOtpContent].
class _OtpContent {
  _OtpContent({
    required this.kind,
    required this.service,
    this.code,
    this.url,
  });

  final String kind;
  final String service;
  final String? code;
  final String? url;
}

/// Fetch the CTA for [noteId] from GET /notification-otp-content.
///
/// Returns null on any error or when the server returns no cta (e.g. the
/// note hasn't synced yet, the user lacks access, or the note has no cta).
Future<_OtpContent?> _fetchOtpContent(
  String apiRoot,
  String token,
  String noteId,
) async {
  try {
    final uri = Uri.parse('$apiRoot/notification-otp-content')
        .replace(queryParameters: {'noteId': noteId});
    final response = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      _bgLog('notification-otp-content HTTP ${response.statusCode}');
      return null;
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final cta = body['cta'];
    if (cta == null || cta is! Map<String, dynamic>) return null;
    return _OtpContent(
      kind: (cta['kind'] as String?) ?? 'otp',
      service: (cta['service'] as String?) ?? '',
      code: cta['code'] as String?,
      url: cta['url'] as String?,
    );
  } catch (e) {
    _bgLog('_fetchOtpContent error: $e');
    return null;
  }
}

/// Show a "Plot signed out — tap to sign in" notification, throttled to at
/// most once per [_signedOutNotifyCooldown] so a burst of pushes doesn't spam
/// the user. Empty payload so tapping opens the app without trying to
/// navigate to a (now-inaccessible) priority.
Future<void> _maybeShowSignedOutNotification(SharedPreferences prefs) async {
  final lastMs = prefs.getInt(_lastSignedOutNotifyKey);
  final now = DateTime.now().millisecondsSinceEpoch;
  if (lastMs != null &&
      now - lastMs < _signedOutNotifyCooldown.inMilliseconds) {
    _bgLog('skipping signed-out notification (cooldown)');
    return;
  }
  try {
    await NotificationDisplay.instance.initialize();
    await NotificationDisplay.instance.showBatchNotification(
      id: _signedOutNotificationId,
      title: 'Plot signed out',
      body: 'Tap to sign in again and resume notifications.',
      targetPriorityId: '',
      urgent: false,
    );
    await prefs.setInt(_lastSignedOutNotifyKey, now);
  } catch (e) {
    _bgLog('failed to show signed-out notification: $e');
  }
}

/// Obtain a Clerk session token using the persisted cache from the main app.
///
/// Returns a [TokenResult] (not a bare `String?`) so the caller can tell a
/// *confirmed-dead* session ([TokenFailureReason.sessionInvalid] → safe to
/// show the "Plot signed out" notification) apart from a *transient* failure
/// ([TokenFailureReason.networkError] → suppress; the session is probably
/// fine). Uses the same [resolveSessionToken] policy as the foreground auth
/// service so the two never disagree.
Future<TokenResult> _getSessionToken(String publishableKey) async {
  clerk.Auth? auth;
  try {
    final cacheDir = await _getClerkCacheDirectory();
    final persistor = clerk.DefaultPersistor(
      getCacheDirectory: () async => cacheDir,
    );
    auth = clerk.Auth(
      config: clerk.AuthConfig(
        publishableKey: publishableKey,
        persistor: persistor,
      ),
    );
    try {
      await auth.initialize().timeout(const Duration(seconds: 10));
    } catch (e) {
      // Init failed or timed out — transient (no network, or a slow cold start
      // while the device is in Doze). NOT a sign-out signal.
      _bgLog('_getSessionToken initialize failed (transient): $e');
      return (token: null, failure: TokenFailureReason.networkError);
    }
    return await resolveSessionToken(
      ClerkSessionOps(auth),
      forceRefresh: false,
      onSessionInvalid: (cause) => _bgLog('session confirmed invalid: $cause'),
    );
  } catch (e) {
    _bgLog('_getSessionToken error: $e');
    return (token: null, failure: TokenFailureReason.networkError);
  } finally {
    auth?.terminate();
  }
}

/// Record that the background isolate concluded the session is CONFIRMED
/// invalid, so the main app can forward it to PostHog on next sign-in. Stored
/// as a timestamp; cleared by the main app after forwarding.
Future<void> _recordBackgroundSessionInvalid(SharedPreferences prefs) async {
  await prefs.setInt(
    _bgSessionInvalidAtKey,
    DateTime.now().millisecondsSinceEpoch,
  );
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

    if (response.statusCode != 200) {
      _bgLog('notification-content HTTP ${response.statusCode}: ${response.body}');
      return null;
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final summaries = body['summaries'] as List?;
    return summaries?.cast<Map<String, dynamic>>();
  } catch (_) {
    return null;
  }
}

/// Schedule notifications to appear at [scheduleAt] using persistent
/// OS-level scheduling (Android AlarmManager / iOS scheduling).
///
/// Survives process termination — the OS delivers the notification even if
/// the app is killed.
Future<void> _scheduleNotifications(
  List<Map<String, dynamic>> summaries,
  DateTime scheduleAt,
) async {
  final delay = scheduleAt.difference(DateTime.now());
  if (delay <= Duration.zero) {
    await showSummaryNotifications(summaries);
    return;
  }

  // Initialize timezone data for zonedSchedule (embedded, no I/O needed)
  await NotificationDisplay.initializeTimezone();

  // Use ID offset to avoid colliding with immediate notification IDs
  const scheduledIdOffset = 100000;

  for (final summary in summaries) {
    final title = summary['title'] as String? ?? 'Updates';
    final body = summary['body'] as String? ?? 'You have new updates';
    final targetPriorityId = summary['target_priority_id'] as String? ?? '';
    final urgent = summary['urgent'] as bool? ?? false;
    final focusLabel = summary['focus_label'] as String?;
    final notifId = scheduledIdOffset +
        (targetPriorityId.hashCode.abs() % 100000);

    await NotificationDisplay.instance.scheduleBatchNotification(
      id: notifId,
      title: title,
      body: body,
      targetPriorityId: targetPriorityId,
      scheduleAt: scheduleAt,
      focusLabel: focusLabel,
      urgent: urgent,
    );
  }

  _bgLog('scheduled ${summaries.length} notifications for $scheduleAt');
}

/// Load persisted thread IDs from SharedPreferences for background dedup.
Map<String, Set<String>>? _loadPersistedThreadIds(SharedPreferences prefs) {
  final raw = prefs.getString(_threadIdsPrefsKey);
  if (raw == null) return null;
  try {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return data.map(
      (k, v) => MapEntry(k, (v as List).cast<String>().toSet()),
    );
  } catch (_) {
    return null;
  }
}

/// Persist thread IDs to SharedPreferences after showing notifications.
Future<void> _persistThreadIds(
  SharedPreferences prefs,
  Map<String, ({int id, Set<String> threadIds})> shown,
) async {
  // Merge with existing data
  final existing = _loadPersistedThreadIds(prefs) ?? {};
  for (final entry in shown.entries) {
    existing[entry.key] = entry.value.threadIds;
  }
  final data = existing.map(
    (k, v) => MapEntry(k, v.toList()..sort()),
  );
  await prefs.setString(_threadIdsPrefsKey, jsonEncode(data));
}

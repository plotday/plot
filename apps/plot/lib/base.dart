import 'dart:async';
import 'dart:typed_data';
import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart';
import 'package:injector/injector.dart';
import 'package:rxdart/rxdart.dart';

import 'package:supabase_flutter/supabase_flutter.dart' as supa;
import 'package:posthog_flutter/posthog_flutter.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/analytics/analytics.dart';
import 'env.dart';
import 'logging.dart';

class User extends Equatable {
  const User(this._baseUser);

  String get id => _baseUser.id;
  String? get primaryEmail => _baseUser.email;
  String? get name => _baseUser.userMetadata?['full_name'] as String?;
  String? get status => _baseUser.appMetadata['status'] as String?;
  String? get contactId => _baseUser.appMetadata['contact_id'] as String?;
  bool get isActive => status == 'active';

  /* private */

  final supa.User _baseUser;

  @override
  List<Object?> get props => [id, primaryEmail, name, status];
}

class Base with WidgetsBindingObserver {
  static supa.SupabaseClient get client =>
      Injector.appInstance.get<Base>()._client!;
  static Stream<User?> get user =>
      Injector.appInstance.get<Base>()._currentUserController.stream;
  static bool get signedIn => Injector.appInstance.get<Base>()._userId != null;
  static Uuid get userId => Injector.appInstance.get<Base>()._userId!;
  static ActorId get actorId => Injector.appInstance.get<Base>()._actorId!;

  static Future<void> init() async {
    try {
      log.info("Initializing Supabase (${Env.supabaseUrl})");
      await supa.Supabase.initialize(
        url: Env.supabaseUrl,
        anonKey: Env.supabaseAnonKey,
      );
      Injector.appInstance.registerSingleton<Base>(() => Base());
      log.info("Supabase ready");
    } catch (e, stack) {
      log.warning("Supabase errore", e, stack);
    }
  }

  /// Checks if the current session is valid (exists and not expired)
  static bool isSessionValid() {
    final session = client.auth.currentSession;
    if (session == null) return false;

    final expiresAt = session.expiresAt;
    if (expiresAt == null) return true; // No expiry means it's valid

    final expiryTime = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
    return DateTime.now().isBefore(expiryTime);
  }

  /// Checks if the session is expiring soon (within 5 minutes)
  static bool isSessionExpiringSoon() {
    final session = client.auth.currentSession;
    if (session == null) return false;

    final expiresAt = session.expiresAt;
    if (expiresAt == null) return false;

    final expiryTime = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
    final fiveMinutesFromNow = DateTime.now().add(const Duration(minutes: 5));
    return expiryTime.isBefore(fiveMinutesFromNow);
  }

  /// Refreshes the session with enhanced error handling
  /// Returns true if refresh succeeded, false otherwise
  static Future<bool> refreshSession({bool isBackground = false}) async {
    try {
      final session = client.auth.currentSession;
      if (session == null) {
        log.info('No session to refresh');
        return false;
      }

      log.info(
        '${isBackground ? "Background" : "Manual"} session refresh attempt',
      );
      final response = await client.auth.refreshSession();

      if (response.session != null) {
        log.info('Session refreshed successfully');
        return true;
      } else {
        log.warning('Session refresh returned null session');
        return false;
      }
    } catch (e, stack) {
      log.warning('Session refresh failed', e, stack);
      return false;
    }
  }

  Base() : _client = supa.Supabase.instance.client, _userId = null {
    _client!.auth.onAuthStateChange.listen((data) {
      _handleAuthStateChange(data);
    });

    // Register lifecycle observer to handle app resume
    WidgetsBinding.instance.addObserver(this);
  }

  /// Handles auth state changes with improved logging and context
  void _handleAuthStateChange(supa.AuthState data) {
    final event = data.event;
    final session = data.session;

    log.info('Auth state change: $event (session: ${session != null})');

    // Log additional context for debugging
    if (session != null) {
      final expiresAt = session.expiresAt;
      if (expiresAt != null) {
        final expiryTime = DateTime.fromMillisecondsSinceEpoch(
          expiresAt * 1000,
        );
        final timeUntilExpiry = expiryTime.difference(DateTime.now());
        log.info(
          'Session expires in: ${timeUntilExpiry.inMinutes} minutes (at $expiryTime)',
        );
      }
    }

    // Handle different auth events
    switch (event) {
      case supa.AuthChangeEvent.signedIn:
        log.info('User signed in');
        break;
      case supa.AuthChangeEvent.signedOut:
        log.info('User signed out');
        break;
      case supa.AuthChangeEvent.tokenRefreshed:
        log.info('Token refreshed successfully');
        break;
      case supa.AuthChangeEvent.userUpdated:
        log.info('User data updated');
        break;
      case supa.AuthChangeEvent.passwordRecovery:
        log.info('Password recovery initiated');
        break;
      default:
        log.info('Other auth event: $event');
    }

    // Intentionally not awaiting to avoid blocking the listener
    _updateUser(session?.user, event);
  }

  final supa.SupabaseClient? _client;
  bool _initialized = false;
  Uuid? _userId;
  ActorId? _actorId;
  DateTime? _signInTime;
  AppLifecycleState? _lastLifecycleState;
  final _currentUserController = BehaviorSubject<User?>();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    log.info('App lifecycle state changed: $_lastLifecycleState -> $state');

    // Handle app resuming from background or inactive state
    if (_lastLifecycleState != null &&
        (_lastLifecycleState == AppLifecycleState.paused ||
            _lastLifecycleState == AppLifecycleState.inactive) &&
        state == AppLifecycleState.resumed) {
      log.info('App resumed, checking session validity');
      _handleAppResume();
    }

    _lastLifecycleState = state;
  }

  /// Handles app resume by checking and refreshing session if needed
  void _handleAppResume() {
    // Don't await - run in background to avoid blocking
    Future(() async {
      if (!signedIn) {
        log.info('Not signed in, skipping session check');
        return;
      }

      // Check if session is expiring soon or already expired
      if (!isSessionValid() || isSessionExpiringSoon()) {
        log.info('Session invalid or expiring, attempting refresh');
        await refreshSession(isBackground: true);
      } else {
        log.info('Session is valid, no refresh needed');
      }
    });
  }

  // Dispose of the StreamController and lifecycle observer
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _currentUserController.close();
  }

  Future<void> _updateUser(
    supa.User? supaUser,
    supa.AuthChangeEvent? event,
  ) async {
    log.info(
      'Updating user: ${supaUser?.id ?? 'null'} (event: ${event?.name ?? 'unknown'})',
    );
    final currentUser = _currentUserController.valueOrNull;
    final newUser = supaUser == null ? null : User(supaUser);

    // Skip if user hasn't changed (same ID and status)
    // Exception: always process token refresh events to ensure session is updated
    if (_initialized &&
        currentUser?.id == newUser?.id &&
        currentUser?.status == newUser?.status &&
        event != supa.AuthChangeEvent.tokenRefreshed) {
      log.info('User unchanged, skipping update');
      return;
    }

    User? user = supaUser == null ? null : User(supaUser);
    _userId = user == null ? null : Uuid.fromString(user.id);
    _actorId = user?.contactId == null
        ? null
        : ActorId.fromString(user!.contactId!);
    _initialized = true;
    if (user == null) {
      // User signing out
      log.info('Processing sign out (previous user: ${currentUser?.id})');

      // Track sign out event with session duration
      if (_signInTime != null) {
        final sessionDurationMs = DateTime.now()
            .difference(_signInTime!)
            .inMilliseconds;
        await Analytics.instance.trackSession(EventAction.signedOut, {
          PropertyKey.sessionDurationMs: sessionDurationMs,
        });
      } else {
        await Analytics.instance.trackSession(EventAction.signedOut);
      }

      await Posthog().flush();
      await Posthog().reset();
      _signInTime = null;
    } else {
      // User signing in or being updated
      if (event == supa.AuthChangeEvent.signedIn) {
        log.info('Processing sign in: ${user.primaryEmail}');
        await Posthog().identify(
          userId: user.id,
          userProperties: {
            ...(user.primaryEmail == null ? {} : {"email": user.primaryEmail!}),
            ...(user.name == null ? {} : {"name": user.name!}),
          },
          userPropertiesSetOnce: {
            "signed_up_time": DateTime.now().toUtc().toIso8601String(),
          },
        );

        // Track sign in event
        _signInTime = DateTime.now();
        await Analytics.instance.trackSession(EventAction.signedIn);
      } else if (event == supa.AuthChangeEvent.tokenRefreshed) {
        log.info('Token refreshed, session updated');
      }
    }
    _currentUserController.add(user);
  }
}

/// Represents a unique user, contact, or twist in Plot.
///
/// ActorIds are used throughout Plot for:
/// - Activity authors and assignees
/// - Tag creators (actor_id in activity_tag/note_tag)
/// - Mentions in activities and notes
/// - Any entity that can perform actions in Plot
///
/// Note: This can be a ContactId OR TwistId, never a UserId directly.
/// For authenticated users, use their ActorId, not their UserId.
extension type ActorId(Uuid value) {
  /// Creates an ActorId from a Uuid
  ActorId.fromUuid(Uuid uuid) : value = uuid;

  /// Creates an ActorId from a string
  ActorId.fromString(String str) : value = Uuid.fromString(str);

  /// Returns the underlying Uuid
  Uuid toUuid() => value;

  Uint8List toBytes() => value.toBytes();
}

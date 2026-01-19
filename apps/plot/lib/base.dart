import 'dart:async';
import 'dart:typed_data';
import 'package:equatable/equatable.dart';
import 'package:injector/injector.dart';
import 'package:rxdart/rxdart.dart';

import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import 'package:plot/util/uuid.dart';
import 'package:plot/analytics/tracker.dart';
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

class Base {
  static supa.SupabaseClient get client =>
      Injector.appInstance.get<Base>()._client!;
  static Stream<User?> get user =>
      Injector.appInstance.get<Base>()._currentUserController.stream;
  static bool get signedIn => Injector.appInstance.get<Base>()._userId != null;
  static Uuid get userId => Injector.appInstance.get<Base>()._userId!;
  static ActorId get actorId => Injector.appInstance.get<Base>()._actorId!;

  /// Clears the actor ID. This should be called after all blocs and Store
  /// are stopped during sign-out to prevent race conditions with streams
  /// that access actorId during cleanup.
  static void clearActorId() {
    Injector.appInstance.get<Base>()._actorId = null;
  }

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

  static Future<supa.AuthResponse> refreshSession() async {
    return await client.auth.refreshSession();
  }

  /// Signs out the current user explicitly.
  /// This is the only place that clears _userId - auth events like token
  /// expiry should not clear it to maintain local-first functionality.
  static Future<void> signOut() async {
    final base = Injector.appInstance.get<Base>();
    final currentUser = base._currentUserController.valueOrNull;

    log.info('Processing explicit sign out (user: ${currentUser?.id})');

    // Clear userId
    base._userId = null;

    // Track analytics
    if (base._signInTime != null) {
      final sessionDurationMs =
          DateTime.now().difference(base._signInTime!).inMilliseconds;
      await Tracker.trackSession(EventAction.signedOut, {
        PropertyKey.sessionDurationMs: sessionDurationMs,
      });
    } else {
      await Tracker.trackSession(EventAction.signedOut);
    }
    await Tracker.reset();
    base._signInTime = null;

    // Emit null to trigger UI sign-out flow
    base._currentUserController.add(null);

    // Then sign out from Supabase
    await base._client!.auth.signOut();
  }

  Base() : _client = supa.Supabase.instance.client, _userId = null {
    _client!.auth.onAuthStateChange.listen((data) {
      _handleAuthStateChange(data);
    });
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
  final _currentUserController = BehaviorSubject<User?>();

  // Dispose of the StreamController
  void dispose() {
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

    // Ignore failed token refreshes - treat as offline, not signed out
    // Supabase will automatically retry token refresh
    if (event == supa.AuthChangeEvent.tokenRefreshed && supaUser == null) {
      log.info(
        'Token refresh failed (likely offline) - keeping user signed in, Supabase will retry',
      );
      return;
    }

    // Ignore signedOut events from Supabase - these can happen due to token
    // expiry while offline. Actual sign-out is handled by Base.signOut() which
    // clears _userId and emits to the user stream before calling Supabase signOut.
    // This maintains local-first functionality when the user is offline.
    if (event == supa.AuthChangeEvent.signedOut) {
      log.info(
        'Received signedOut event from Supabase - no action (sign-out handled by Base.signOut() if intentional)',
      );
      return;
    }

    // Skip if user hasn't changed (same ID and status)
    // Exception: always process token refresh and user updated events
    if (_initialized &&
        currentUser?.id == newUser?.id &&
        currentUser?.status == newUser?.status &&
        event != supa.AuthChangeEvent.tokenRefreshed &&
        event != supa.AuthChangeEvent.userUpdated) {
      log.info('User unchanged, skipping update');
      return;
    }

    // At this point, we have a valid user (signedOut and tokenRefreshed with
    // null user are handled above). Set _userId - never clear it here.
    User? user = supaUser == null ? null : User(supaUser);
    if (user != null) {
      _userId = Uuid.fromString(user.id);
      _actorId = user.contactId == null
          ? null
          : ActorId.fromString(user.contactId!);
    }
    _initialized = true;

    // Handle sign-in and token refresh events
    if (event == supa.AuthChangeEvent.signedIn && user != null) {
      log.info('Processing sign in: ${user.primaryEmail}');
      await Tracker.identify(
        user.id,
        properties: {
          ...(user.primaryEmail == null ? {} : {"email": user.primaryEmail!}),
          ...(user.name == null ? {} : {"name": user.name!}),
        },
        propertiesSetOnce: {
          "signed_up_time": DateTime.now().toUtc().toIso8601String(),
        },
      );

      // Track sign in event
      _signInTime = DateTime.now();
      await Tracker.trackSession(EventAction.signedIn);
    } else if (event == supa.AuthChangeEvent.tokenRefreshed) {
      log.info('Token refreshed, session updated');
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

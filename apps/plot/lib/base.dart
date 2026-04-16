import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:equatable/equatable.dart';
import 'package:injector/injector.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/auth/auth_service.dart';
export 'package:plot/auth/auth_service.dart'
    show TokenResult, TokenFailureReason;
import 'package:plot/util/uuid.dart';
import 'package:plot/util/profile_preferences.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/network_exception.dart';
import 'env.dart';
import 'cli_args.dart';
import 'logging.dart';

class User extends Equatable {
  const User({required this.id, this.primaryEmail, this.name, this.contactId});

  final String id; // UUID from public."user"
  final String? primaryEmail;
  final String? name;
  final String? contactId;

  @override
  List<Object?> get props => [id, primaryEmail, name];
}

class Base {
  static AuthService get auth => Injector.appInstance.get<Base>()._auth;
  static Stream<User?> get user =>
      Injector.appInstance.get<Base>()._currentUserController.stream;
  static bool get signedIn => Injector.appInstance.get<Base>()._userId != null;

  /// Emits when the session is definitively dead and the user will be
  /// signed out. Listeners can show a brief toast before the sign-out
  /// state transition cleans up the UI.
  static Stream<void> get needsReAuth =>
      Injector.appInstance.get<Base>()._needsReAuthController.stream;

  static Uuid get userId => Injector.appInstance.get<Base>()._userId!;
  static ActorId get actorId => Injector.appInstance.get<Base>()._actorId!;
  static ActorId? get actorIdOrNull => Injector.appInstance.get<Base>()._actorId;

  /// True when identity was set via sign-in or /activate (not restored from
  /// local storage). UserBloc uses this to decide whether to call /activate
  /// in the background.
  static bool get isFreshSignIn =>
      Injector.appInstance.get<Base>()._freshSignIn;

  /// Clears the actor ID. This should be called after all blocs and Store
  /// are stopped during sign-out to prevent race conditions with streams
  /// that access actorId during cleanup.
  static void clearActorId() {
    Injector.appInstance.get<Base>()._actorId = null;
  }

  /// In-flight token fetch completer — serializes concurrent requests so
  /// only one Clerk call happens at a time.
  static Completer<TokenResult>? _tokenFetchInFlight;

  /// Get session token with failure reason. Serializes concurrent calls.
  static Future<TokenResult> getSessionTokenWithReason() async {
    if (_tokenFetchInFlight != null) {
      return _tokenFetchInFlight!.future;
    }
    _tokenFetchInFlight = Completer<TokenResult>();
    try {
      final result = await auth.getSessionTokenWithReason();
      _tokenFetchInFlight!.complete(result);
      return result;
    } catch (e) {
      final result = (
        token: null as String?,
        failure: TokenFailureReason.networkError,
      );
      _tokenFetchInFlight!.complete(result);
      return result;
    } finally {
      _tokenFetchInFlight = null;
    }
  }

  /// Get session token for API calls.
  /// Returns null if not signed in or token cannot be obtained.
  static Future<String?> getSessionToken() async {
    final result = await getSessionTokenWithReason();
    return result.token;
  }

  /// Act on a token result: sign out immediately on [TokenFailureReason.sessionInvalid],
  /// clear the re-auth flag on success.
  static void handleTokenResult(TokenResult result) {
    if (result.failure == TokenFailureReason.sessionInvalid) {
      _forceSignOut();
    } else if (result.token != null) {
      // Successful token — reset the re-auth guard.
      Injector.appInstance.get<Base>()._reAuthSignaled = false;
    }
  }

  /// Emit the re-auth signal (for toast), then sign out. Guarded to
  /// prevent re-entry from multiple concurrent callers.
  static void _forceSignOut() {
    final base = Injector.appInstance.get<Base>();
    if (base._reAuthSignaled) return;
    base._reAuthSignaled = true;
    log.warning('Session invalid — forcing sign-out');
    base._needsReAuthController.add(null);
    // Sign out asynchronously — the UI listener will show a toast first.
    Future.microtask(() => signOut());
  }

  static Future<void> init() async {
    log.info("Initializing Clerk auth");

    // Step 1: Create auth service (may fail if Clerk is down)
    AuthService authService;
    try {
      authService = await createAuthService(
        publishableKey: Env.clerkPublishableKey,
        profile: CliArgs.profile,
      );
    } catch (e, stack) {
      log.warning("Clerk auth initialization failed, using fallback", e, stack);
      authService = FailedAuthService();
    }

    // Step 2: Always register Base so the app can proceed
    final base = Base._(authService);
    Injector.appInstance.registerSingleton<Base>(() => base);

    // Step 3: Try to restore identity from local storage (no network needed)
    try {
      await base._restoreIdentity();
    } catch (e, stack) {
      log.warning("Failed to restore identity from local storage", e, stack);
    }

    // Step 4: If Clerk has a session but local identity wasn't restored, OR
    // the restored identity is incomplete (userId present but contactId/
    // actorId missing — e.g. pre-contact-id app versions), resolve via API.
    // Skip if using FailedAuthService (no session possible).
    final localIdentityIncomplete =
        base._userId != null && base._actorId == null;
    if ((!base._currentUserController.hasValue || localIdentityIncomplete) &&
        authService is! FailedAuthService &&
        authService.isSignedIn) {
      log.info(
        localIdentityIncomplete
            ? 'Local identity missing contact ID, resolving identity'
            : 'Clerk session found without local identity, resolving identity',
      );
      try {
        await Base.resolveIdentity();
      } catch (e, stack) {
        log.warning('Failed to resolve identity on startup', e, stack);
        // Session token is likely expired/invalid. Sign out of Clerk so the
        // user can sign in fresh instead of being stuck ("already signed in").
        log.info('Signing out stale Clerk session');
        try {
          await authService.signOut();
        } catch (signOutError) {
          log.warning('Failed to sign out stale session', signOutError);
        }
      }
    }

    // Step 5: Ensure the user stream always emits so the UI can proceed
    if (!base._currentUserController.hasValue) {
      log.info('No identity available, emitting signed-out state');
      base._currentUserController.add(null);
    }

    log.info("Clerk auth ready");
  }

  /// Called after successful Clerk sign-in to activate and set identity.
  static Future<void> activate() async {
    final result = await api.post<Map<String, dynamic>>('/activate');
    await Injector.appInstance.get<Base>().setIdentity(
      userId: result['userId'] as String,
      email: result['email'] as String?,
      name: result['name'] as String?,
      contactId: result['contactId'] as String?,
    );
  }

  /// Try to extract identity from JWT claims without an API call.
  /// Returns null if required fields are missing (e.g. first sign-in before
  /// /activate has set external_id and contact_id in the JWT).
  static Future<User?> identityFromJwt() async {
    final token = await getSessionToken();
    if (token == null) return null;
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
              )
              as Map<String, dynamic>;
      final userId = payload['external_id'] as String?;
      final contactId = payload['contact_id'] as String?;
      if (userId == null || contactId == null) return null;
      return User(
        id: userId,
        primaryEmail: payload['email'] as String?,
        name: payload['name'] as String?,
        contactId: contactId,
      );
    } catch (e) {
      log.warning('Failed to decode JWT payload: $e');
      return null;
    }
  }

  /// Resolve identity by calling /activate — server is the source of truth.
  /// This handles stale JWTs (e.g. after a database reset) by always asking
  /// the server for the correct user ID. Falls back to JWT on network error.
  static Future<void> resolveIdentity() async {
    // Try /activate first — server is the source of truth for user identity.
    try {
      final result = await api.post<Map<String, dynamic>>('/activate');
      final userId = result['userId'] as String;

      await Injector.appInstance.get<Base>().setIdentity(
        userId: userId,
        email: result['email'] as String?,
        name: result['name'] as String?,
        contactId: result['contactId'] as String?,
      );

      // If the server assigned a different user ID than what's in the JWT,
      // refresh the Clerk client so future JWTs have the correct external_id.
      final jwtUser = await identityFromJwt();
      if (jwtUser == null || jwtUser.id != userId) {
        try {
          await auth.refreshClient();
        } catch (e) {
          log.warning(
            'Failed to refresh Clerk client after identity change: $e',
          );
        }
      }
      return;
    } on NetworkException {
      // Network unavailable — fall back to JWT identity
      log.info('Cannot reach /activate, falling back to JWT identity');
    }

    // Fallback: use JWT claims directly (original fast path)
    final jwtUser = await identityFromJwt();
    if (jwtUser != null) {
      await Injector.appInstance.get<Base>().setIdentity(
        userId: jwtUser.id,
        email: jwtUser.primaryEmail,
        name: jwtUser.name,
        contactId: jwtUser.contactId,
      );
      return;
    }

    // Neither /activate nor JWT worked
    throw Exception(
      'Unable to resolve identity: /activate failed and JWT has no identity',
    );
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
      final sessionDurationMs = DateTime.now()
          .difference(base._signInTime!)
          .inMilliseconds;
      await Tracker.trackSession(EventAction.signedOut, {
        PropertyKey.sessionDurationMs: sessionDurationMs,
      });
    } else {
      await Tracker.trackSession(EventAction.signedOut);
    }
    await Tracker.reset();
    base._signInTime = null;

    // Clear stored identity
    await base._clearStoredIdentity();

    // Emit null to trigger UI sign-out flow
    base._currentUserController.add(null);

    // Sign out from Clerk
    await base._auth.signOut();
  }

  Base._(this._auth);

  final AuthService _auth;
  Uuid? _userId;
  ActorId? _actorId;
  DateTime? _signInTime;
  bool _freshSignIn = false;
  bool _reAuthSignaled = false;
  final _currentUserController = BehaviorSubject<User?>();
  final _needsReAuthController = StreamController<void>.broadcast();

  void dispose() {
    _currentUserController.close();
    _needsReAuthController.close();
  }

  /// Restore user identity from ProfilePreferences after auth init.
  /// Called during Base.init() — if we have stored identity, emit the user
  /// immediately (no network call needed). We trust stored identity because
  /// it's explicitly cleared on sign-out, so its presence means the user
  /// didn't sign out. This avoids depending on Clerk's isSignedIn which may
  /// not be ready immediately after initialize().
  Future<void> _restoreIdentity() async {
    final prefs = ProfilePreferences.instance;
    final storedUserId = prefs.getString('clerk_user_id');
    final storedEmail = prefs.getString('clerk_user_email');
    final storedName = prefs.getString('clerk_user_name');
    final storedContactId = prefs.getString('clerk_user_contact_id');

    if (storedUserId != null) {
      _userId = Uuid.fromString(storedUserId);
      _actorId = storedContactId != null
          ? ActorId.fromString(storedContactId)
          : null;

      final user = User(
        id: storedUserId,
        primaryEmail: storedEmail,
        name: storedName,
        contactId: storedContactId,
      );

      log.info(
        'Restored user identity from local storage: ${user.primaryEmail}',
      );
      _currentUserController.add(user);
    }
  }

  /// Called after successful /activate to store identity locally and emit user.
  /// This is the ONLY place that creates and emits a User after sign-in.
  Future<void> setIdentity({
    required String userId,
    required String? email,
    required String? name,
    required String? contactId,
  }) async {
    _userId = Uuid.fromString(userId);
    _actorId = contactId != null ? ActorId.fromString(contactId) : null;
    _signInTime = DateTime.now();
    _freshSignIn = true;

    // Detect new user before persisting identity
    final prefs = ProfilePreferences.instance;
    final isNewUser = prefs.getString('clerk_user_id') == null;

    // Persist identity for offline restoration
    await prefs.setString('clerk_user_id', userId);
    if (email != null) await prefs.setString('clerk_user_email', email);
    if (name != null) await prefs.setString('clerk_user_name', name);
    if (contactId != null) {
      await prefs.setString('clerk_user_contact_id', contactId);
    }

    final user = User(
      id: userId,
      primaryEmail: email,
      name: name,
      contactId: contactId,
    );

    // Identify user in PostHog
    await Tracker.identify(
      userId,
      properties: {
        if (email != null) "email": email,
        if (name != null) "name": name,
      },
      propertiesSetOnce: {
        "signed_up_time": DateTime.now().toUtc().toIso8601String(),
      },
    );

    // Track signup vs sign-in
    if (isNewUser) {
      await Tracker.trackEvent(
        category: EventCategory.user,
        object: EventObject.user,
        action: EventAction.signedUp,
      );
    }
    await Tracker.trackSession(EventAction.signedIn);

    _currentUserController.add(user);
  }

  Future<void> _clearStoredIdentity() async {
    final prefs = ProfilePreferences.instance;
    await prefs.remove('clerk_user_id');
    await prefs.remove('clerk_user_email');
    await prefs.remove('clerk_user_name');
    await prefs.remove('clerk_user_contact_id');
  }
}

/// Represents a unique user, contact, or twist in Plot.
///
/// ActorIds are used throughout Plot for:
/// - Thread authors and assignees
/// - Tag creators (actor_id in thread_tag/note_tag)
/// - Mentions in threads and notes
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

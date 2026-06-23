import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:injector/injector.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/auth/auth_service.dart';
export 'package:plot/auth/auth_service.dart'
    show TokenResult, TokenFailureReason;
import 'package:plot/util/uuid.dart';
import 'package:plot/util/profile_preferences.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/auth/sign_in_retry.dart'
    show IdentityResolutionException, isTransientSignInError, retryAsync;
import 'package:plot/state/pending_send.dart';
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
  /// The Clerk-backed [AuthService]. Only valid after [awaitAuthReady] resolves
  /// — on warm starts [init] returns before Clerk has finished initializing so
  /// callers that touch this directly (UI sign-in flow, [AutoSignIn]) must
  /// await readiness first. Token-fetching paths route through
  /// [getSessionTokenWithReason] which gates internally.
  static AuthService get auth => Injector.appInstance.get<Base>()._auth;

  /// Completes once Clerk has finished initializing and [_auth] is assigned.
  /// On warm starts (returning user with restored local identity) [init]
  /// returns before this resolves so the app can open Drift in parallel.
  static Future<void> awaitAuthReady() =>
      Injector.appInstance.get<Base>()._authReadyCompleter.future;

  static Stream<User?> get user =>
      Injector.appInstance.get<Base>()._currentUserController.stream;
  static bool get signedIn => Injector.appInstance.get<Base>()._userId != null;

  /// Emits when the session is definitively dead and the user will be
  /// signed out. Listeners can show a brief toast before the sign-out
  /// state transition cleans up the UI.
  static Stream<void> get needsReAuth =>
      Injector.appInstance.get<Base>()._needsReAuthController.stream;

  static Uuid get userId => Injector.appInstance.get<Base>()._userId!;
  static Uuid? get userIdOrNull => Injector.appInstance.get<Base>()._userId;
  static ActorId get actorId => Injector.appInstance.get<Base>()._actorId!;
  static ActorId? get actorIdOrNull =>
      Injector.appInstance.get<Base>()._actorId;

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

  /// Registers a minimal [Base] instance suitable for unit tests that need
  /// [Base.actorId] to resolve (e.g. [Note.draft] or [ThreadBloc.sendWithUndo]).
  /// Must be paired with a [tearDown] that calls [removeForTesting].
  @visibleForTesting
  static void initForTesting(ActorId actorId) {
    final base = Base._();
    base._actorId = actorId;
    Injector.appInstance.registerSingleton<Base>(() => base, override: true);
  }

  /// Removes the [Base] singleton registered by [initForTesting].
  @visibleForTesting
  static void removeForTesting() {
    Injector.appInstance.removeByKey<Base>();
  }

  /// In-flight token fetch completer — serializes concurrent requests so
  /// only one Clerk call happens at a time.
  static Completer<TokenResult>? _tokenFetchInFlight;

  /// Get session token with failure reason. Serializes concurrent calls.
  ///
  /// [forceRefresh] is passed through to [AuthService.getSessionTokenWithReason]
  /// — sync layers (store / broadcast) set it after seeing a 401 so we
  /// reconcile with Clerk's server rather than handing back the same
  /// stale JWT from cache. If a force-refresh is in flight when a
  /// regular fetch arrives (or vice versa), the in-flight call wins —
  /// a force-refresh subsumes a regular fetch, and a regular fetch is
  /// satisfied by the more thorough force-refresh result.
  static Future<TokenResult> getSessionTokenWithReason({
    bool forceRefresh = false,
  }) async {
    if (_tokenFetchInFlight != null) {
      return _tokenFetchInFlight!.future;
    }
    _tokenFetchInFlight = Completer<TokenResult>();
    try {
      // Warm-start path: [init] returns before Clerk finishes initializing,
      // so wait for [_auth] to be assigned before touching it.
      await Injector.appInstance.get<Base>()._authReadyCompleter.future;
      final result = await auth.getSessionTokenWithReason(
        forceRefresh: forceRefresh,
      );
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
    // Persist so the sign-in screen can show a "session expired" banner even
    // if sign-out fires during cold start, before any UI listener is attached.
    ProfilePreferences.instance.setBool(_forceSignedOutKey, true);
    base._needsReAuthController.add(null);
    // Sign out asynchronously — the UI listener will show a toast first.
    Future.microtask(() => signOut());
  }

  static const _forceSignedOutKey = 'session_force_signed_out';

  /// Whether the last sign-out was triggered by [_forceSignOut] (i.e. Clerk
  /// reported the session invalid). Cleared on the next successful sign-in
  /// or explicit sign-out. Used by the sign-in page to show a banner.
  static bool get wasForceSignedOut =>
      ProfilePreferences.instance.getBool(_forceSignedOutKey) ?? false;

  /// Clear the force-signed-out flag. Called after the sign-in page has
  /// acknowledged the banner (e.g. when the user taps "Dismiss").
  static Future<void> clearForceSignedOut() =>
      ProfilePreferences.instance.remove(_forceSignedOutKey);

  static Future<void> init() async {
    log.info("Initializing Clerk auth");

    // Register Base immediately so identity-restoration can emit on the user
    // stream. _auth is late-assigned inside _initAuthService() once Clerk
    // finishes initializing.
    final base = Base._();
    Injector.appInstance.registerSingleton<Base>(() => base);

    // Restore identity from local storage first — no network or Clerk call
    // needed. For returning users this emits a User on the BehaviorSubject
    // immediately so UserBloc can open the Drift DB (Store.start) in parallel
    // with Clerk initialization.
    try {
      await base._restoreIdentity();
    } catch (e, stack) {
      log.warning("Failed to restore identity from local storage", e, stack);
    }

    final localIdentityIncomplete =
        base._userId != null && base._actorId == null;
    final hasRestoredIdentity =
        base._currentUserController.valueOrNull != null &&
        !localIdentityIncomplete;

    if (hasRestoredIdentity) {
      // Warm start: Clerk runs in the background. Token-using paths
      // (getSessionTokenWithReason) await _authReadyCompleter; the UI never
      // touches Base.auth before UserBloc emits UserReady, by which point
      // /activate-validated identity has typically resolved.
      unawaited(base._initAuthService());
      log.info("Clerk init running in parallel with Drift open");
    } else {
      // Cold start, signed-out, or pre-contact-id local identity: must
      // finish Clerk init before returning so the sign-in UI or
      // resolveIdentity can run synchronously.
      await base._initAuthService();
    }
  }

  /// Creates the Clerk auth service, wires its session-invalidation stream,
  /// resolves/validates identity, and unblocks token-fetch callers via
  /// [_authReadyCompleter]. Called by [init] — synchronously on cold starts,
  /// in the background on warm starts so Drift can open in parallel.
  Future<void> _initAuthService() async {
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

    _auth = authService;
    // Unblock token-fetch callers as soon as _auth is assignable. The
    // identity-resolution paths below themselves call into the API (via
    // resolveIdentity → /activate → getSessionTokenWithReason), which would
    // deadlock if we held the completer until they finished.
    _authReadyCompleter.complete();

    // Listen for asynchronous Clerk session-invalidation signals (e.g. the
    // background token poller surfacing `authentication_invalid`). Without
    // this, the SDK's cached JWT keeps superficially looking valid and the
    // user gets stuck with a dead session until they manually sign out.
    authService.sessionInvalidatedStream.listen((_) {
      log.warning('Clerk reported session invalid via error stream');
      Base.handleTokenResult((
        token: null,
        failure: TokenFailureReason.sessionInvalid,
      ));
    });

    final localIdentityIncomplete = _userId != null && _actorId == null;
    final hasRestoredIdentity =
        _currentUserController.valueOrNull != null && !localIdentityIncomplete;

    // When Clerk has a session, validate identity with the server.
    // - If we couldn't restore local identity (first sign-in) or it's
    //   incomplete (userId present but contactId/actorId missing — e.g.
    //   pre-contact-id app versions): block on /activate, sign out of
    //   Clerk on failure so the user can sign in fresh.
    // - If we have a complete restored identity: validate in the background
    //   with a timeout. App startup proceeds with the restored identity. If
    //   /activate returns a different user.id (e.g. after a DB reset, or in
    //   dev when switching between APIs backed by different databases),
    //   resolveIdentity() signs out so the user reauthenticates fresh —
    //   silently swapping userIds underneath the restored data was leaving
    //   sync wedged on a Broadcast DO 403. Failures are non-fatal — the user
    //   keeps working with restored data.
    // Skip entirely when using FailedAuthService (no session possible).
    if (authService is! FailedAuthService && authService.isSignedIn) {
      if (!hasRestoredIdentity) {
        log.info(
          localIdentityIncomplete
              ? 'Local identity missing contact ID, resolving identity'
              : 'Clerk session found without local identity, resolving identity',
        );
        try {
          await Base.resolveIdentity();
        } catch (e, stack) {
          log.warning('Failed to resolve identity on startup', e, stack);
          // Session token is likely expired/invalid. Sign out of Clerk so
          // the user can sign in fresh instead of being stuck ("already
          // signed in").
          log.info('Signing out stale Clerk session');
          try {
            await authService.signOut();
          } catch (signOutError) {
            log.warning('Failed to sign out stale session', signOutError);
          }
        }
      } else {
        log.info('Validating restored identity with /activate in background');
        unawaited(Base._validateRestoredIdentity());
      }
    }

    // Ensure the user stream always emits so the UI can proceed.
    if (!_currentUserController.hasValue) {
      log.info('No identity available, emitting signed-out state');
      _currentUserController.add(null);
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

  /// Background validation of a restored identity. Calls /activate with a
  /// short timeout; failures are swallowed so the user keeps working with
  /// their restored identity. If the server returns a different user.id
  /// (e.g. after a server-side DB reset), setIdentity() emits a new User
  /// and UserBloc tears down and rebuilds the Store under the new identity.
  static Future<void> _validateRestoredIdentity() async {
    try {
      await resolveIdentity().timeout(const Duration(seconds: 10));
    } on TimeoutException {
      log.info(
        'Background /activate timed out — continuing with restored identity',
      );
    } catch (e, stack) {
      log.warning(
        'Background /activate failed — continuing with restored identity',
        e,
        stack,
      );
    }
  }

  /// Resolve identity by calling /activate — server is the source of truth.
  /// This handles stale JWTs (e.g. after a database reset) by always asking
  /// the server for the correct user ID. Falls back to JWT on network error.
  static Future<void> resolveIdentity() async {
    // Snapshot the locally-stored userId before /activate runs. If the server
    // resolves to a different user.id, the local identity is stale and any
    // local data is keyed to a userId the server doesn't agree is ours — the
    // WebSocket would loop forever on 403 from the Broadcast DO's path/JWT
    // check. Sign out so the user reauthenticates against the current API
    // and starts clean, instead of silently swapping identity and leaving
    // sync wedged. Only triggers when local identity was already restored
    // (returning user pointing at a stale or otherwise-different backend);
    // first-time sign-ins have `_userId == null` here and are unaffected.
    final localUserIdBeforeActivate = Injector.appInstance
        .get<Base>()
        ._userId
        ?.toString();

    // Try /activate first — server is the source of truth for user identity.
    try {
      final result = await api.post<Map<String, dynamic>>('/activate');
      final userId = result['userId'] as String;

      if (localUserIdBeforeActivate != null &&
          localUserIdBeforeActivate != userId) {
        log.warning(
          '/activate resolved a different user (local='
          '$localUserIdBeforeActivate server=$userId) — signing out to avoid '
          'wedged sync against a backend that does not recognize the cached '
          'identity',
        );
        await signOut();
        return;
      }

      await Injector.appInstance.get<Base>().setIdentity(
        userId: userId,
        email: result['email'] as String?,
        name: result['name'] as String?,
        contactId: result['contactId'] as String?,
      );

      // Reconcile the cached Clerk JWT against the server's resolved userId.
      // Two cases land here, and NEITHER warrants signing the user out:
      //   * jwtUser == null — first sign-in: the JWT predates /activate, so it
      //     carries no external_id / contact_id yet.
      //   * jwtUser.id != userId — the in-hand JWT carries a stale external_id
      //     left over from a previous backend (a dev DB reset, or switching
      //     between APIs backed by different databases). /activate has ALREADY
      //     re-pointed the Clerk user's external_id at `userId` above, so the
      //     mismatch lives only in the locally-cached token, not the server's
      //     record of who we are.
      // A genuinely wedged identity — local data keyed to a userId the server
      // no longer agrees is ours — is caught earlier by the
      // localUserIdBeforeActivate check, which signs out. Reaching this point
      // means local data is consistent (first sign-in with no local data, or
      // local == server), so we keep the user signed in and only refresh the
      // Clerk client. The REST API already tolerates the stale external_id
      // (getUser falls back to clerk_id), and the realtime /updates channel
      // self-heals once Clerk's session-token cache (~60s) refreshes to the
      // corrected external_id — refreshClient() alone does not bust that
      // cache, so we don't block on it. The prior behavior signed out here,
      // which bounced users off a fresh DB on their very first sign-in.
      final jwtUser = await identityFromJwt();
      if (jwtUser == null || jwtUser.id != userId) {
        if (jwtUser != null) {
          log.warning(
            'JWT external_id (${jwtUser.id}) disagrees with server userId '
            '($userId) — refreshing Clerk client and staying signed in; '
            'sync heals once the session token refreshes',
          );
        }
        try {
          await auth.refreshClient();
        } catch (e) {
          log.warning('Failed to refresh Clerk client: $e');
        }
      }
      return;
    } on NetworkException {
      // Network unavailable — fall back to JWT identity
      log.info('Cannot reach /activate, falling back to JWT identity');
    } on ApiException catch (e) {
      // API reachable but unhealthy (502/503/504 etc.) — let returning users
      // proceed with the identity claims already in their JWT. First-time
      // sign-ups still fail at the JWT step below because external_id /
      // contact_id only land in the JWT after a successful /activate. 4xx
      // is rethrown — those indicate request-level problems that the JWT
      // fallback can't paper over.
      if (e.statusCode < 500) rethrow;
      log.info(
        '/activate returned ${e.statusCode}, falling back to JWT identity',
      );
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

    // Neither /activate nor JWT worked. Use a typed exception so the
    // first-time sign-in retry loop treats this as transient — a stalled or
    // mid-deploy /activate may well succeed on the next attempt.
    throw const IdentityResolutionException(
      '/activate failed and JWT has no identity',
    );
  }

  /// Resolve identity via [resolveIdentity], retrying transient backend
  /// stalls. A *fresh install* (App Store reviewer, new device) has no
  /// restored identity to fall back on, so this leg must succeed during
  /// sign-in. `/activate` is idempotent, so re-issuing it across a brief
  /// backend burst is safe — this turns a one-shot timeout into resilience.
  ///
  /// [attemptTimeout] is kept below the API client's own 30s request timeout
  /// so a stalled attempt is abandoned and retried while the burst clears.
  static Future<void> resolveIdentityResilient({
    Duration attemptTimeout = const Duration(seconds: 15),
    int maxAttempts = 3,
  }) => retryAsync(
    () => resolveIdentity().timeout(attemptTimeout),
    maxAttempts: maxAttempts,
    isRetryable: isTransientSignInError,
  );

  /// Signs out the current user explicitly.
  /// This is the only place that clears _userId - auth events like token
  /// expiry should not clear it to maintain local-first functionality.
  static Future<void> signOut() async {
    final base = Injector.appInstance.get<Base>();
    final currentUser = base._currentUserController.valueOrNull;

    log.info('Processing explicit sign out (user: ${currentUser?.id})');

    // Send any in-flight "SENDING" note under the still-authenticated session
    // before clearing identity.
    try {
      await PendingSend.instance.flush();
    } catch (e, t) {
      log.warning('Failed to flush pending send on sign-out', e, t);
    }

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
    // Only _forceSignOut sets this; clear on explicit sign-out too so we
    // don't show a stale "session expired" banner after a manual sign-out.
    await ProfilePreferences.instance.remove(_forceSignedOutKey);

    // Emit null to trigger UI sign-out flow
    base._currentUserController.add(null);

    // Sign out from Clerk
    await base._auth.signOut();
  }

  Base._();

  late final AuthService _auth;
  final Completer<void> _authReadyCompleter = Completer<void>();
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
    // Successful re-auth clears the "session expired" banner.
    await prefs.remove(_forceSignedOutKey);

    final user = User(
      id: userId,
      primaryEmail: email,
      name: name,
      contactId: contactId,
    );

    // Identify user in PostHog
    await Tracker.identify(
      userId,
      properties: {"email": ?email, "name": ?name},
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

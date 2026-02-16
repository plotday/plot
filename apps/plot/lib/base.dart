import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:equatable/equatable.dart';
import 'package:injector/injector.dart';
import 'package:rxdart/rxdart.dart';
import 'package:path_provider/path_provider.dart';

import 'package:clerk_auth/clerk_auth.dart' as clerk;

import 'package:plot/util/uuid.dart';
import 'package:plot/util/profile_preferences.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api.dart' as api;
import 'env.dart';
import 'cli_args.dart';
import 'logging.dart';

class User extends Equatable {
  const User({
    required this.id,
    this.primaryEmail,
    this.name,
    this.contactId,
  });

  final String id; // UUID from public."user"
  final String? primaryEmail;
  final String? name;
  final String? contactId;

  @override
  List<Object?> get props => [id, primaryEmail, name];
}

class Base {
  static clerk.Auth get auth => Injector.appInstance.get<Base>()._auth;
  static Stream<User?> get user =>
      Injector.appInstance.get<Base>()._currentUserController.stream;
  static bool get signedIn => Injector.appInstance.get<Base>()._userId != null;
  static Uuid get userId => Injector.appInstance.get<Base>()._userId!;
  static ActorId get actorId => Injector.appInstance.get<Base>()._actorId!;

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

  /// Get session token for API calls.
  /// Returns null if not signed in or token cannot be obtained.
  /// clerk_auth handles token refresh automatically.
  static Future<String?> getSessionToken() async {
    try {
      final token = await auth.sessionToken();
      return token.jwt;
    } catch (e) {
      log.warning('Failed to get session token: $e');
      return null;
    }
  }

  static Future<void> init() async {
    try {
      log.info("Initializing Clerk auth");

      final profile = CliArgs.profile;
      final cacheDir = await _getClerkCacheDirectory(profile);

      final clerkAuth = clerk.Auth(
        config: clerk.AuthConfig(
          publishableKey: Env.clerkPublishableKey,
          persistor: clerk.DefaultPersistor(
            getCacheDirectory: () async => cacheDir,
          ),
        ),
      );
      await clerkAuth.initialize();

      final base = Base._(clerkAuth);
      Injector.appInstance.registerSingleton<Base>(() => base);

      // Restore identity from local storage (doesn't require network)
      await base._restoreIdentity();

      // If Clerk has a session but local identity wasn't restored (e.g. first
      // sign-in with Clerk, or preferences were cleared), activate via API.
      if (!base._currentUserController.hasValue && clerkAuth.isSignedIn) {
        log.info('Clerk session found without local identity, resolving identity');
        try {
          await Base.resolveIdentity();
        } catch (e, stack) {
          log.warning('Failed to resolve identity on startup', e, stack);
          // Session token is likely expired/invalid. Sign out of Clerk so the
          // user can sign in fresh instead of being stuck ("already signed in").
          log.info('Signing out stale Clerk session');
          try {
            await clerkAuth.signOut();
          } catch (signOutError) {
            log.warning('Failed to sign out stale session', signOutError);
          }
        }
      }

      // Ensure the user stream emits a value so the UI can proceed.
      if (!base._currentUserController.hasValue) {
        log.info('No identity available, emitting signed-out state');
        base._currentUserController.add(null);
      }

      log.info("Clerk auth ready");
    } catch (e, stack) {
      log.warning("Clerk auth error", e, stack);
    }
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
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;
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

  /// Resolve identity: try JWT decode first, fall back to /activate.
  /// After /activate, refresh the Clerk client so the cached JWT
  /// picks up the newly-set publicMetadata (contact_id).
  static Future<void> resolveIdentity() async {
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
    // New user or missing metadata — full activate
    await activate();
    // Refresh client so Clerk issues a fresh JWT with the new publicMetadata
    try {
      await auth.refreshClient();
    } catch (e) {
      log.warning('Failed to refresh Clerk client after activate (non-blocking)', e);
    }
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

  final clerk.Auth _auth;
  Uuid? _userId;
  ActorId? _actorId;
  DateTime? _signInTime;
  bool _freshSignIn = false;
  final _currentUserController = BehaviorSubject<User?>();

  void dispose() {
    _currentUserController.close();
  }

  /// Restore user identity from ProfilePreferences after clerk_auth init.
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

      log.info('Restored user identity from local storage: ${user.primaryEmail}');
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

    // Persist identity for offline restoration
    final prefs = ProfilePreferences.instance;
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

    // Track sign-in
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

  /// Get clerk cache directory, isolated per profile.
  static Future<Directory> _getClerkCacheDirectory(String? profile) async {
    final appSupport = await getApplicationSupportDirectory();
    final dirName = profile != null
        ? 'clerk_profile_$profile'
        : 'clerk';
    final dir = Directory('${appSupport.path}/$dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
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

/// Shared types and interface for platform-agnostic authentication.
library;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Strategies for the [AuthService.attemptSignIn] method.
enum AuthStrategy {
  emailAddress,
  password,
  emailCode,
  resetPasswordEmailCode,
}

/// OAuth id-token providers supported by [AuthService.signInWithIdToken].
enum IdTokenProvider {
  google,
  apple,
}

/// Error codes surfaced by [AuthError].
enum AuthErrorCode {
  noSuchFirstFactorStrategy,
  noAssociatedStrategy,
  serverErrorResponse,
  unknown,
}

/// Why a token fetch failed — lets callers distinguish transient network
/// problems (retry) from definitive session rejection (sign out).
enum TokenFailureReason {
  /// Network unreachable, DNS failure, Clerk 5xx, timeout, etc.
  networkError,

  /// Clerk API was reachable and explicitly rejected the session.
  sessionInvalid,
}

/// Result of [AuthService.getSessionTokenWithReason].
typedef TokenResult = ({String? token, TokenFailureReason? failure});

// ---------------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------------

/// A unified auth error thrown by both native and web [AuthService]
/// implementations. Mirrors the surface of `clerk.ClerkError` that the
/// UI layer inspects.
class AuthError implements Exception {
  const AuthError({
    required this.message,
    this.argument,
    this.code = AuthErrorCode.unknown,
    this.clerkCode,
  });

  /// Raw error message (may contain template placeholders).
  final String message;

  /// Human-readable interpolated message, when available.
  final String? argument;

  /// Categorised error code.
  final AuthErrorCode code;

  /// The raw Clerk server error code (e.g. `authorization_invalid`,
  /// `external_account_not_found`), when this wraps a server response —
  /// otherwise null. The categorised [code] deliberately collapses most
  /// server errors to [AuthErrorCode.serverErrorResponse], which is fine for
  /// branching UI but erases the detail needed to tell distinct failures
  /// apart in telemetry (they also share a stack fingerprint in error
  /// tracking). Capture sites forward this to PostHog as `clerk_code`.
  final String? clerkCode;

  @override
  String toString() {
    if (argument != null) return argument!;
    return message;
  }
}

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------

/// Platform-agnostic authentication service.
///
/// The method signatures intentionally mirror `clerk_auth`'s [Auth] class so
/// that call-site changes are minimal.
abstract class AuthService {
  /// Whether the user currently has an active session.
  bool get isSignedIn;

  /// The list of fields still required to complete sign-up, or `null` if there
  /// is no active sign-up.
  List<String>? get signUpMissingFields;

  /// Returns the current session JWT, or `null` if not signed in.
  Future<String?> getSessionToken();

  /// Like [getSessionToken] but also reports *why* the fetch failed so
  /// callers can distinguish network errors from dead sessions.
  ///
  /// When [forceRefresh] is true, callers (e.g. sync layer reacting to a
  /// 401) ask the implementation to bypass any locally cached session
  /// token and reconcile with Clerk's server first. Without this, a
  /// server-side session revocation can stay invisible for the lifetime
  /// of the cached JWT — `_auth.sessionToken()` keeps returning the same
  /// stale token, sync keeps 401-ing, and we loop forever without ever
  /// surfacing a sign-out signal.
  ///
  /// Default implementation wraps [getSessionToken] — subclasses should
  /// override with proper error classification.
  Future<TokenResult> getSessionTokenWithReason({
    bool forceRefresh = false,
  }) async {
    final token = await getSessionToken();
    return (
      token: token,
      failure: token == null ? TokenFailureReason.sessionInvalid : null,
    );
  }

  /// Fires when the underlying auth provider asynchronously discovers that
  /// the session is no longer valid (e.g. clerk_auth's background token
  /// poller surfaces `authentication_invalid` / `signed_out`). Lets [Base]
  /// force sign-out without waiting for the next API request to 401.
  Stream<void> get sessionInvalidatedStream => const Stream<void>.empty();

  // -- Sign-in ---------------------------------------------------------------

  /// Sign in using an id-token obtained from a native OAuth SDK
  /// (Google Sign-In, Sign In With Apple, etc.).
  Future<void> signInWithIdToken({
    required IdTokenProvider provider,
    required String idToken,
  });

  /// Start a browser-based OAuth redirect flow (web only).
  ///
  /// Redirects the browser to the provider's OAuth page via Clerk. After
  /// the user authenticates, the page reloads and the session is active.
  /// On native platforms this throws [UnsupportedError].
  Future<void> signInWithRedirect({required IdTokenProvider provider});

  /// Sign up using an id-token (same as [signInWithIdToken] but creates the
  /// account if it doesn't exist).
  Future<void> signUpWithIdToken({
    required IdTokenProvider provider,
    required String idToken,
  });

  /// Whether the current sign-in requires a second factor (e.g. email code
  /// verification on an untrusted device).
  bool get needsSecondFactor;

  /// Two-step email/password sign-in.
  ///
  /// Step 1: `attemptSignIn(strategy: .emailAddress, identifier: email)`
  /// Step 2: `attemptSignIn(strategy: .password, password: password)`
  Future<void> attemptSignIn({
    required AuthStrategy strategy,
    String? identifier,
    String? password,
  });

  /// Redeem a server-issued Clerk sign-in ticket. The ticket bypasses
  /// Clerk's first-factor flow entirely, so the caller is responsible for
  /// having verified credentials before requesting it.
  Future<void> signInWithTicket({required String ticket});

  /// Prepare second-factor verification (sends email code).
  Future<void> prepareSecondFactor();

  /// Attempt second-factor verification with the emailed code.
  Future<void> attemptSecondFactor({required String code});

  /// Progressive sign-up (email code + password).
  Future<void> attemptSignUp({
    required AuthStrategy strategy,
    String? emailAddress,
    String? code,
    String? password,
    String? passwordConfirmation,
    String? firstName,
    String? lastName,
  });

  /// Transfer a pending sign-up into a sign-in (or vice versa).
  Future<void> transfer();

  /// Initiate a password reset by emailing the user a one-time code.
  /// Step 1 of the reset flow; followed by [resetPassword] once the user
  /// has the code in hand.
  Future<void> initiatePasswordReset({required String email});

  /// Complete a password reset using the emailed [code] and the user's
  /// chosen [password]. On success the user is signed in.
  Future<void> resetPassword({required String code, required String password});

  // -- User management -------------------------------------------------------

  /// Update the signed-in user's profile.
  Future<void> updateUser({String? firstName, String? lastName});

  /// Set the signed-in user's password without requiring the current one.
  /// Used when finishing a sign-up where Clerk's instance treated the email
  /// code as sufficient to create the session — the user has no password
  /// yet, so the standard "change password" API (which demands the current
  /// password) doesn't apply.
  Future<void> setUserPassword({required String password});

  // -- Client management -----------------------------------------------------

  /// Refresh the Clerk client state (re-fetches from API).
  Future<void> refreshClient();

  /// Reset the Clerk client (creates a new client).
  Future<void> resetClient();

  /// Sign out the current session.
  Future<void> signOut();
}

/// Fallback [AuthService] used when Clerk initialization fails entirely.
/// Returns safe defaults for all queries and throws on any sign-in attempt.
/// On next app restart Clerk will likely initialize successfully.
class FailedAuthService implements AuthService {
  @override
  bool get isSignedIn => false;

  @override
  List<String>? get signUpMissingFields => null;

  @override
  bool get needsSecondFactor => false;

  @override
  Future<String?> getSessionToken() async => null;

  @override
  Future<TokenResult> getSessionTokenWithReason({
    bool forceRefresh = false,
  }) async => (token: null, failure: TokenFailureReason.networkError);

  @override
  Stream<void> get sessionInvalidatedStream => const Stream<void>.empty();

  @override
  Future<void> signInWithIdToken({
    required IdTokenProvider provider,
    required String idToken,
  }) =>
      throw const AuthError(
        message: 'Authentication unavailable, please restart the app.',
      );

  @override
  Future<void> signInWithRedirect({required IdTokenProvider provider}) =>
      throw const AuthError(
        message: 'Authentication unavailable, please restart the app.',
      );

  @override
  Future<void> signUpWithIdToken({
    required IdTokenProvider provider,
    required String idToken,
  }) =>
      throw const AuthError(
        message: 'Authentication unavailable, please restart the app.',
      );

  @override
  Future<void> attemptSignIn({
    required AuthStrategy strategy,
    String? identifier,
    String? password,
  }) =>
      throw const AuthError(
        message: 'Authentication unavailable, please restart the app.',
      );

  @override
  Future<void> signInWithTicket({required String ticket}) =>
      throw const AuthError(
        message: 'Authentication unavailable, please restart the app.',
      );

  @override
  Future<void> prepareSecondFactor() => throw const AuthError(
    message: 'Authentication unavailable, please restart the app.',
  );

  @override
  Future<void> attemptSecondFactor({required String code}) =>
      throw const AuthError(
        message: 'Authentication unavailable, please restart the app.',
      );

  @override
  Future<void> attemptSignUp({
    required AuthStrategy strategy,
    String? emailAddress,
    String? code,
    String? password,
    String? passwordConfirmation,
    String? firstName,
    String? lastName,
  }) =>
      throw const AuthError(
        message: 'Authentication unavailable, please restart the app.',
      );

  @override
  Future<void> transfer() => throw const AuthError(
    message: 'Authentication unavailable, please restart the app.',
  );

  @override
  Future<void> initiatePasswordReset({required String email}) =>
      throw const AuthError(
        message: 'Authentication unavailable, please restart the app.',
      );

  @override
  Future<void> resetPassword({required String code, required String password}) =>
      throw const AuthError(
        message: 'Authentication unavailable, please restart the app.',
      );

  @override
  Future<void> updateUser({String? firstName, String? lastName}) =>
      throw const AuthError(
        message: 'Authentication unavailable, please restart the app.',
      );

  @override
  Future<void> setUserPassword({required String password}) =>
      throw const AuthError(
        message: 'Authentication unavailable, please restart the app.',
      );

  @override
  Future<void> refreshClient() async {}

  @override
  Future<void> resetClient() async {}

  @override
  Future<void> signOut() async {}
}

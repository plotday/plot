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
  });

  /// Raw error message (may contain template placeholders).
  final String message;

  /// Human-readable interpolated message, when available.
  final String? argument;

  /// Categorised error code.
  final AuthErrorCode code;

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

  // -- Sign-in ---------------------------------------------------------------

  /// Sign in using an id-token obtained from a native OAuth SDK
  /// (Google Sign-In, Sign In With Apple, etc.).
  Future<void> signInWithIdToken({
    required IdTokenProvider provider,
    required String idToken,
  });

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

  // -- User management -------------------------------------------------------

  /// Update the signed-in user's profile.
  Future<void> updateUser({String? firstName, String? lastName});

  // -- Client management -----------------------------------------------------

  /// Refresh the Clerk client state (re-fetches from API).
  Future<void> refreshClient();

  /// Reset the Clerk client (creates a new client).
  Future<void> resetClient();

  /// Sign out the current session.
  Future<void> signOut();
}

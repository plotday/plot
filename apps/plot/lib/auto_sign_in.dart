import 'package:logging/logging.dart';

import 'package:plot/auth/auth_service.dart';
import 'base.dart';
import 'cli_args.dart';
import 'util/profile_preferences.dart';

/// Service for handling automatic sign-in from command-line arguments.
///
/// Supports:
/// - --user=EMAIL: Sign in as user (sign out first if different user)
/// - --password=PASSWORD: Auto sign-in with password (requires --user)
class AutoSignIn {
  AutoSignIn._();

  static final Logger _log = Logger('AutoSignIn');
  static bool _initialized = false;
  static bool _signInInProgress = false;

  /// Initializes auto sign-in based on CLI arguments.
  ///
  /// Must be called after Base.init() to ensure Clerk is ready.
  static Future<void> init() async {
    if (_initialized) {
      _log.warning('AutoSignIn already initialized');
      return;
    }

    _initialized = true;

    final targetUser = CliArgs.user;
    if (targetUser == null) {
      return;
    }

    _log.info('Auto sign-in requested for user: $targetUser');

    try {
      // Check current user
      final isSignedIn = Base.signedIn;
      final currentEmail = ProfilePreferences.instance.getString(
        'clerk_user_email',
      );

      if (isSignedIn && currentEmail != null) {
        if (currentEmail.toLowerCase() == targetUser.toLowerCase()) {
          _log.info('Already signed in as target user: $targetUser');
          return;
        }

        _log.info(
          'Signed in as different user ($currentEmail), signing out first',
        );
        await Base.signOut();
        // Wait a moment for sign-out to complete
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      // If password is provided, sign in immediately
      final password = CliArgs.password;
      if (password != null) {
        _log.info('Attempting auto sign-in with password');
        _signInInProgress = true;

        try {
          // Two-step sign-in
          await Base.auth.attemptSignIn(
            strategy: AuthStrategy.emailAddress,
            identifier: targetUser,
          );
          await Base.auth.attemptSignIn(
            strategy: AuthStrategy.password,
            password: password,
          );
          await Base.resolveIdentity();
          _log.info('Auto sign-in successful');
        } catch (e) {
          _log.warning('Auto sign-in failed: $e');
          // Don't rethrow - let the app continue and show sign-in page
        } finally {
          _signInInProgress = false;
        }
      } else {
        _log.info('No password provided, user will need to sign in manually');
        // The app will navigate to sign-in page with the email pre-filled
      }
    } catch (e, stack) {
      _log.warning('Error during auto sign-in setup', e, stack);
    }
  }

  /// Returns true if auto sign-in is currently in progress.
  static bool get isInProgress => _signInInProgress;

  /// Returns the target user email from CLI args, if any.
  static String? get targetUser => CliArgs.user;

  /// Returns true if we should navigate to sign-in with pre-filled email.
  static bool get shouldNavigateToSignIn =>
      CliArgs.user != null && CliArgs.password == null;
}

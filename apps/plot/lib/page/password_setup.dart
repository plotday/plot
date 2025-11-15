import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/base.dart';
import 'package:plot/state/user.dart';
import 'package:plot/router.dart' show InvitationRoute;
import 'logging.dart';

@RoutePage()
class PasswordSetupPage extends StatefulWidget {
  const PasswordSetupPage({this.returnTo, super.key});

  final String? returnTo;

  @override
  State<PasswordSetupPage> createState() => _PasswordSetupPageState();
}

class _PasswordSetupPageState extends State<PasswordSetupPage> {
  String? _errorMessage;
  String? _successMessage;
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  bool _attemptedDeepLink = false;

  @override
  void initState() {
    super.initState();
    // On web, attempt to deep link to the native app
    if (kIsWeb && !_attemptedDeepLink) {
      _attemptDeepLink();
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _attemptDeepLink() async {
    setState(() {
      _attemptedDeepLink = true;
    });

    // Try to open the app using deep link
    try {
      // Attempt to redirect to the app
      // Note: This will work if the app is installed and handles the deep link
      // If not, the user will remain on the web page
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // We can't actually trigger the deep link from Flutter web without url_launcher
      // So for now, we'll just show the web UI
      // TODO: Add url_launcher_web package if deep linking from web is needed
    } catch (e) {
      // Silently fail - user will use web UI
      log.info('Deep link attempt failed (expected on web): $e');
    }
  }

  Future<void> _handlePasswordUpdate() async {
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (password.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a password';
      });
      return;
    }

    if (password.length < 8) {
      setState(() {
        _errorMessage = 'Password must be at least 8 characters';
      });
      return;
    }

    if (password != confirmPassword) {
      setState(() {
        _errorMessage = 'Passwords do not match';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Update the user's password and clear the password_setup_required flag
      final response = await Base.client.auth.updateUser(
        UserAttributes(
          password: password,
          data: {'password_setup_required': false},
        ),
      );

      if (response.user == null) {
        throw Exception('Failed to update password');
      }

      if (!mounted) return;

      setState(() {
        _successMessage = 'Password set successfully! Redirecting...';
        _isLoading = false;
      });

      // The BlocListener will handle navigation when the user state updates
      // to UserReady or UserWaitlisted
    } on AuthException catch (e) {
      log.warning('Error updating password', e);
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to set password: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<UserBloc, UserState>(
      listener: (context, state) {
        // Only navigate after password has been successfully set
        if (_successMessage != null) {
          if (state is UserReady) {
            // Navigate to the main app when user is ready
            context.router.navigatePath(widget.returnTo ?? '/');
          } else if (state is UserWaitlisted) {
            // Navigate to invitation page for waitlisted users
            context.router.navigate(const InvitationRoute());
          }
        }
        // If UserPasswordRequired, stay on this page (user hasn't set password yet)
      },
      child: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                spacing: 16,
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Title
                  const Text(
                    'Set your password',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const Text(
                    'Choose a secure password for your account',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF6B7280),
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Success message
                  if (_successMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF10B981).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        _successMessage!,
                        style: const TextStyle(color: Color(0xFF10B981)),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ] else ...[
                    // Password field
                    FTextField(
                      controller: _passwordController,
                      hint: 'Enter your password',
                      label: const Text('Password'),
                      obscureText: true,
                      autofocus: true,
                      onSubmit: (_) => _handlePasswordUpdate(),
                    ),

                    // Confirm password field
                    FTextField(
                      controller: _confirmPasswordController,
                      hint: 'Re-enter your password',
                      label: const Text('Confirm Password'),
                      obscureText: true,
                      onSubmit: (_) => _handlePasswordUpdate(),
                    ),

                    // Submit button
                    SizedBox(
                      height: 44,
                      child: FButton(
                        onPress: _isLoading ? null : _handlePasswordUpdate,
                        style: FButtonStyle.primary(),
                        child: _isLoading ? const Spinner() : const Text('Set Password'),
                      ),
                    ),
                  ],

                  // Error message
                  if (_errorMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Color(0xFFEF4444)),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

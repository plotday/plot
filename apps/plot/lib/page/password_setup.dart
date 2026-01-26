import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/base.dart';
import 'package:plot/state/user.dart';
import 'package:plot/router.dart';
import 'package:plot/util/profile_preferences.dart';
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
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  bool _isPasswordReset = false;

  @override
  void initState() {
    super.initState();
    _loadResetMode();
  }

  Future<void> _loadResetMode() async {
    final prefs = ProfilePreferences.instance;
    setState(() {
      _isPasswordReset = prefs.getBool('is_password_reset') ?? false;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handlePasswordUpdate() async {
    final name = _nameController.text.trim();
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    // Only validate name for new users (not password reset)
    if (!_isPasswordReset && name.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your name';
      });
      return;
    }

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
      // Update the user's password (and name for new users)
      final response = await Base.client.auth.updateUser(
        UserAttributes(
          password: password,
          data: _isPasswordReset ? null : {'full_name': name},
        ),
      );

      if (response.user == null) {
        throw Exception('Failed to update password');
      }

      // Clear the reset mode flag
      final prefs = ProfilePreferences.instance;
      await prefs.remove('is_password_reset');

      if (!mounted) return;

      // Clear the local password setup flag
      // This will trigger UserReady state and allow navigation
      await context.read<UserBloc>().setPasswordSetupRequired(false);
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

  Future<void> _handleCancel() async {
    // Get the user's email before clearing state
    final userState = context.read<UserBloc>().state;
    final email = userState is UserPasswordRequired
        ? userState.user.primaryEmail
        : null;

    // Clear both flags and navigate back to sign-in page
    final prefs = ProfilePreferences.instance;
    await prefs.remove('is_password_reset');

    if (!mounted) return;
    await context.read<UserBloc>().setPasswordSetupRequired(false);

    if (!mounted) return;
    // Navigate to email sign-in page, which should automatically sign in
    await context.router.navigate(EmailSignInRoute(email: email));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      center: true,
      body: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            spacing: 16,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title
              Text(
                _isPasswordReset
                    ? 'Reset your password'
                    : 'Complete your account',
                style: context.theme.typography.lg.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),

              Text(
                _isPasswordReset
                    ? 'Choose a new secure password'
                    : 'Enter your name and choose a secure password',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF6B7280)),
              ),

              const SizedBox(height: 8),

              // Name field (only for new users)
              if (!_isPasswordReset)
                FTextField(
                  control: .managed(controller: _nameController),
                  hint: 'Enter your name',
                  label: const Text('Name'),
                  autofocus: true,
                  onSubmit: (_) => _handlePasswordUpdate(),
                ),

              // Password field
              FTextField(
                control: .managed(controller: _passwordController),
                hint: _isPasswordReset
                    ? 'Enter new password'
                    : 'Enter your password',
                label: const Text('Password'),
                obscureText: true,
                autofocus: _isPasswordReset,
                onSubmit: (_) => _handlePasswordUpdate(),
              ),

              // Confirm password field
              FTextField(
                control: .managed(controller: _confirmPasswordController),
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
                  child: _isLoading
                      ? const Spinner()
                      : Text(
                          _isPasswordReset
                              ? 'Reset Password'
                              : 'Create Account',
                        ),
                ),
              ),

              // Cancel button (only for password reset)
              if (_isPasswordReset)
                FButton(
                  onPress: _isLoading ? null : _handleCancel,
                  style: FButtonStyle.ghost(),
                  child: const Text('Cancel and sign in'),
                ),

              // Error message
              if (_errorMessage != null) ...[
                FAlert(
                  style: FAlertStyle.destructive(),
                  title: Text(_errorMessage!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

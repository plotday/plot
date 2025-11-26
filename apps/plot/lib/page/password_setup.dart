import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/base.dart';
import 'package:plot/state/user.dart';
import 'package:logging/logging.dart';
import 'logging.dart';

@RoutePage()
class PasswordSetupPage extends StatefulWidget {
  const PasswordSetupPage({this.returnTo, this.onPasswordSet, super.key});

  final String? returnTo;
  final void Function()? onPasswordSet;

  @override
  State<PasswordSetupPage> createState() => _PasswordSetupPageState();
}

class _PasswordSetupPageState extends State<PasswordSetupPage> {
  String? _errorMessage;
  String? _successMessage;
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
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
      // Update the user's password
      final response = await Base.client.auth.updateUser(
        UserAttributes(password: password),
      );

      if (response.user == null) {
        throw Exception('Failed to update password');
      }

      if (!mounted) return;

      // Clear the local password setup flag
      // This will trigger UserReady state and allow navigation
      await context.read<UserBloc>().setPasswordSetupRequired(false);

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
        if (state is UserReady && widget.onPasswordSet != null) {
          Logger('plot.route').info('PasswordSetupPage: UserReady detected, calling onPasswordSet callback');
          widget.onPasswordSet!();
        }
      },
      child: Scaffold(
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
                  'Set your password',
                  style: context.theme.typography.lg.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),

                const Text(
                  'Choose a secure password for your account',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF6B7280)),
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
                      child: _isLoading
                          ? const Spinner()
                          : const Text('Set Password'),
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
    );
  }
}

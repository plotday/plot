import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/base.dart';
import 'package:plot/state/user.dart';
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

  @override
  void initState() {
    super.initState();
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

    if (name.isEmpty) {
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
      // Update the user's password and name
      final response = await Base.client.auth.updateUser(
        UserAttributes(password: password, data: {'full_name': name}),
      );

      if (response.user == null) {
        throw Exception('Failed to update password');
      }

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
                'Complete your account',
                style: context.theme.typography.lg.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),

              const Text(
                'Enter your name and choose a secure password',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF6B7280)),
              ),

              const SizedBox(height: 8),

              // Name field
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
                hint: 'Enter your password',
                label: const Text('Password'),
                obscureText: true,
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
                      : const Text('Create Account'),
                ),
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

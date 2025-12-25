import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/base.dart';
import 'package:plot/state/user.dart';
import 'logging.dart';

@RoutePage()
class EmailSignInPage extends StatefulWidget {
  const EmailSignInPage({this.returnTo, super.key});

  final String? returnTo;

  @override
  State<EmailSignInPage> createState() => _EmailSignInPageState();
}

enum _AuthMode { signIn, signUp, otpSent }

class _EmailSignInPageState extends State<EmailSignInPage> {
  String? _errorMessage;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _otpController = TextEditingController();
  _AuthMode _mode = _AuthMode.signIn;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _handleSignIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your email address';
      });
      return;
    }

    if (password.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your password';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await Base.client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      // Clear password setup flag for password sign-ins
      // (they already have a password)
      if (mounted) {
        await context.read<UserBloc>().clearPasswordSetupRequired();
      }
    } on AuthException catch (e) {
      log.warning('Error signing in with password', e);
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleSignUp() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your email address';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Send OTP code for new account signup
      await Base.client.auth.signInWithOtp(email: email);

      // Successfully sent OTP
      setState(() {
        _mode = _AuthMode.otpSent;
        _isLoading = false;
      });
    } on AuthException catch (e) {
      log.warning('Error sending signup OTP', e);
      setState(() {
        _errorMessage = e.message;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to send verification code: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _handlePasswordReset() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your email address';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Send OTP for password reset
      await Base.client.auth.signInWithOtp(email: email);
      if (!mounted) return;
      setState(() {
        _mode = _AuthMode.otpSent;
        _isLoading = false;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleVerifyOtp() async {
    final email = _emailController.text.trim();
    final token = _otpController.text.trim();

    if (token.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter the verification code';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await Base.client.auth.verifyOTP(
        email: email,
        token: token,
        type: OtpType.email,
      );

      if (!mounted) return;

      // Set local flag to indicate password setup is required
      // This will trigger UserPasswordRequired or UserWaitlisted state
      await context.read<UserBloc>().setPasswordSetupRequired(true);
    } on AuthException catch (e) {
      log.warning('Error verifying OTP', e);
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to verify code: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _handleResendCode() async {
    final email = _emailController.text.trim();

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await Base.client.auth.signInWithOtp(email: email);

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _otpController.clear();
      });
    } on AuthException catch (e) {
      log.warning('Error resending code', e);
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
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
            spacing: 8,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title
              Text(
                _mode == _AuthMode.signUp
                    ? 'Create your account'
                    : 'Sign in to Plot',
                style: context.theme.typography.xl.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),

              // OTP sent confirmation with code entry
              if (_mode == _AuthMode.otpSent) ...[
                FAlert(
                  title: const Text(
                    'Check your email!\nWe sent a verification code to',
                  ),
                  subtitle: Text(
                    _emailController.text.trim(),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  'Enter the 6-digit code from your email:',
                  style: context.theme.typography.base,
                  textAlign: TextAlign.center,
                ),

                // OTP input field
                OtpInput(
                  controller: _otpController,
                  onComplete: _handleVerifyOtp,
                ),

                const SizedBox(height: 8),

                // Resend and try different email buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FButton(
                      onPress: _isLoading ? null : _handleResendCode,
                      style: FButtonStyle.ghost(),
                      child: const Text('Resend code'),
                    ),
                    const SizedBox(width: 8),
                    const Text('•'),
                    const SizedBox(width: 8),
                    FButton(
                      onPress: () {
                        setState(() {
                          _mode = _AuthMode.signIn;
                          _errorMessage = null;
                          _otpController.clear();
                        });
                      },
                      style: FButtonStyle.ghost(),
                      child: const Text('Different email'),
                    ),
                  ],
                ),
              ] else ...[
                // Email field
                FTextField(
                  control: .managed(controller: _emailController),
                  hint: 'your@email.com',
                  label: const Text('Email'),
                  keyboardType: TextInputType.emailAddress,
                  autofocus: true,
                  autocorrect: false,
                  onSubmit: (_) => _mode == _AuthMode.signUp
                      ? _handleSignUp()
                      : _handleSignIn(),
                ),

                // Password field (only in sign-in mode)
                if (_mode == _AuthMode.signIn) ...[
                  Column(
                    spacing: 2,
                    children: [
                      FTextField(
                        control: .managed(controller: _passwordController),
                        hint: 'Enter your password',
                        label: const Text('Password'),
                        obscureText: true,
                        onSubmit: (_) => _handleSignIn(),
                      ),
                      // Forgot password link
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          FButton(
                            onPress: _isLoading ? null : _handlePasswordReset,
                            style: FButtonStyle.ghost(),
                            child: const Text('Reset password'),
                          ),
                          FButton(
                            onPress: _isLoading
                                ? null
                                : () {
                                    setState(() {
                                      _mode = _mode == _AuthMode.signUp
                                          ? _AuthMode.signIn
                                          : _AuthMode.signUp;
                                      _passwordController.clear();
                                      _errorMessage = null;
                                    });
                                  },
                            style: FButtonStyle.ghost(),
                            child: const Text('Sign up instead'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],

                // Submit button
                SizedBox(
                  height: 44,
                  child: FButton(
                    onPress: _isLoading
                        ? null
                        : (_mode == _AuthMode.signUp
                              ? _handleSignUp
                              : _handleSignIn),
                    style: FButtonStyle.primary(),
                    child: _isLoading
                        ? const Spinner()
                        : Text(
                            _mode == _AuthMode.signUp ? 'Continue' : 'Sign In',
                          ),
                  ),
                ),

                // Back button
                FButton(
                  onPress: () => context.router.maybePop(),
                  style: FButtonStyle.ghost(),
                  child: const Text('Use another sign-in method'),
                ),
              ],

              // Error message
              if (_errorMessage != null) ...[
                FAlert(
                  style: FAlertStyle.destructive(),
                  title: Text(_errorMessage!),
                ),
              ],

              const SizedBox(height: 16),
              const TermsAgreement(),
            ],
          ),
        ),
      ),
    );
  }
}

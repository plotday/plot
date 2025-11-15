import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/base.dart';
import 'package:plot/state/user.dart';
import 'package:plot/router.dart' show InvitationRoute, PasswordSetupRoute;
import 'package:plot/env.dart';
import 'logging.dart';

@RoutePage()
class EmailAuthPage extends StatefulWidget {
  const EmailAuthPage({this.returnTo, super.key});

  final String? returnTo;

  @override
  State<EmailAuthPage> createState() => _EmailAuthPageState();
}

enum _AuthMode { signIn, signUp, magicLinkSent }

class _EmailAuthPageState extends State<EmailAuthPage> {
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
      // Send magic link for new account signup
      final redirectUrl = Env.authServerCallbackUrl.replaceAll(
        '/auth.html',
        '/password-setup',
      );
      await Base.client.auth.signInWithOtp(
        email: email,
        emailRedirectTo: redirectUrl,
      );

      // Successfully sent magic link
      setState(() {
        _mode = _AuthMode.magicLinkSent;
        _isLoading = false;
      });
    } on AuthException catch (e) {
      log.warning('Error sending signup magic link', e);
      setState(() {
        _errorMessage = e.message;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to send magic link: $e';
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
      final redirectUrl = Env.authServerCallbackUrl.replaceAll(
        '/auth.html',
        '/password-setup',
      );
      await Base.client.auth.resetPasswordForEmail(
        email,
        redirectTo: redirectUrl,
      );
      if (!mounted) return;
      setState(() {
        _mode = _AuthMode.magicLinkSent;
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

      // Set metadata flag to indicate password setup is required
      await Base.client.auth.updateUser(
        UserAttributes(
          data: {'password_setup_required': true},
        ),
      );

      // The UserBloc will detect the passwordRequired flag and emit
      // UserPasswordRequired state, which will trigger navigation to
      // password setup via AuthGuard
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
      final redirectUrl = Env.authServerCallbackUrl.replaceAll(
        '/auth.html',
        '/password-setup',
      );
      await Base.client.auth.signInWithOtp(
        email: email,
        emailRedirectTo: redirectUrl,
      );

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
    return BlocListener<UserBloc, UserState>(
      listener: (context, state) {
        // Navigate when user is ready (Store.init has completed)
        if (state is UserReady) {
          context.router.navigatePath(widget.returnTo ?? '/');
        } else if (state is UserPasswordRequired) {
          // Navigate to password setup page
          context.router.navigate(
            PasswordSetupRoute(returnTo: widget.returnTo),
          );
        } else if (state is UserWaitlisted) {
          // Navigate to invitation page for waitlisted users
          context.router.navigate(const InvitationRoute());
        }
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
                  Text(
                    _mode == _AuthMode.signUp
                        ? 'Create your account'
                        : 'Sign in to your account',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 8),

                  // Magic link sent confirmation with OTP entry
                  if (_mode == _AuthMode.magicLinkSent) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF10B981).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        spacing: 4,
                        children: [
                          const Text(
                            'Check your email! We sent you a link and a code.',
                            style: TextStyle(color: Color(0xFF10B981)),
                            textAlign: TextAlign.center,
                          ),
                          Text(
                            _emailController.text.trim(),
                            style: const TextStyle(
                              color: Color(0xFF10B981),
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),

                    const Text(
                      'Enter the 6-digit code from your email:',
                      style: TextStyle(fontSize: 14),
                      textAlign: TextAlign.center,
                    ),

                    // OTP input field
                    FTextField(
                      controller: _otpController,
                      hint: '000000',
                      label: const Text('Verification code'),
                      keyboardType: TextInputType.number,
                      autofocus: true,
                      autocorrect: false,
                      maxLength: 6,
                      onSubmit: (_) => _handleVerifyOtp(),
                    ),

                    // Verify button
                    SizedBox(
                      height: 44,
                      child: FButton(
                        onPress: _isLoading ? null : _handleVerifyOtp,
                        style: FButtonStyle.primary(),
                        child: _isLoading
                            ? const Spinner()
                            : const Text('Verify code'),
                      ),
                    ),

                    // Divider with "or"
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 1,
                            color: const Color(0xFFE5E7EB),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'or',
                            style: TextStyle(
                              color: const Color(0xFF6B7280).withValues(alpha: 0.8),
                              fontSize: 14,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Container(
                            height: 1,
                            color: const Color(0xFFE5E7EB),
                          ),
                        ),
                      ],
                    ),

                    const Text(
                      'Click the link in your email',
                      style: TextStyle(fontSize: 14),
                      textAlign: TextAlign.center,
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
                      controller: _emailController,
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
                        children: [
                          FTextField(
                            controller: _passwordController,
                            hint: 'Enter your password',
                            label: const Text('Password'),
                            obscureText: true,
                            onSubmit: (_) => _handleSignIn(),
                          ),
                          // Forgot password link
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              FButton(
                                onPress: _isLoading
                                    ? null
                                    : _handlePasswordReset,
                                style: FButtonStyle.ghost(),
                                child: const Text('Forgot password?'),
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
                                _mode == _AuthMode.signUp
                                    ? 'Continue'
                                    : 'Sign in',
                              ),
                      ),
                    ),

                    // Toggle between sign-in and sign-up
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
                      child: Text(
                        _mode == _AuthMode.signUp
                            ? 'Already have an account? Sign in'
                            : 'Don\'t have an account? Sign up',
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

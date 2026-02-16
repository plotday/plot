import 'dart:async';
import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:auto_route/auto_route.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/base.dart';
import 'package:plot/router.dart' show PasswordSetupRoute;
import 'logging.dart';

@RoutePage()
class EmailSignInPage extends StatefulWidget {
  const EmailSignInPage({this.returnTo, this.email, super.key});

  final String? returnTo;
  final String? email;

  @override
  State<EmailSignInPage> createState() => _EmailSignInPageState();
}

enum _AuthMode { signIn, signUp, otpSent }

class _EmailSignInPageState extends State<EmailSignInPage> {
  String? _errorMessage;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _otpController = TextEditingController();
  final _emailFocusNode = FocusNode();
  _AuthMode _mode = _AuthMode.signIn;
  bool _isLoading = false;
  int _otpResetCounter = 0;

  @override
  void initState() {
    super.initState();
    if (widget.email != null) {
      _emailController.text = widget.email!;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    _emailFocusNode.dispose();
    super.dispose();
  }

  void _showGenericError(Object error, StackTrace? stackTrace) {
    Tracker.captureException(error, stackTrace);
    if (!mounted) return;
    setState(() {
      _errorMessage = 'Something went wrong. Please try again.';
      _isLoading = false;
    });
  }

  String _clerkErrorMessage(clerk.ClerkError e) {
    // For server errors, the human-readable message is in .argument
    // (.message contains a raw '{arg}' template).
    if (e.argument != null) return e.argument!;
    return e.message;
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
      // clerk_auth uses a two-step sign-in flow:
      // 1. Identify with email
      await Base.auth.attemptSignIn(
        strategy: clerk.Strategy.emailAddress,
        identifier: email,
      );
      // 2. Authenticate with password
      await Base.auth.attemptSignIn(
        strategy: clerk.Strategy.password,
        password: password,
      );

      // Call /activate to get user identity
      await Base.resolveIdentity();
      // UserBloc will pick up the emission and transition to UserReady
    } on clerk.ClerkError catch (e, t) {
      log.warning('Error signing in with password', e, t);
      if (!mounted) return;
      setState(() {
        _errorMessage = _clerkErrorMessage(e);
        _isLoading = false;
      });
    } on NetworkException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to connect. Please check your internet.';
        _isLoading = false;
      });
    } catch (e, t) {
      log.warning('Error signing in with password', e, t);
      _showGenericError(e, t);
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
      // Start sign-up flow — Clerk sends the email code
      await Base.auth.attemptSignUp(
        strategy: clerk.Strategy.emailCode,
        emailAddress: email,
      );
      setState(() {
        _mode = _AuthMode.otpSent;
        _isLoading = false;
      });
    } on clerk.ClerkError catch (e, t) {
      log.warning('Error sending signup OTP', e, t);
      if (!mounted) return;
      setState(() {
        _errorMessage = _clerkErrorMessage(e);
        _isLoading = false;
      });
    } on NetworkException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to connect. Please check your internet.';
        _isLoading = false;
      });
    } catch (e, t) {
      log.warning('Error sending signup OTP', e, t);
      _showGenericError(e, t);
    }
  }

  Future<void> _handlePasswordReset() async {
    // Use the same OTP flow for password reset
    await _handleSignUp();
  }

  Future<void> _handleVerifyOtp() async {
    if (_isLoading) return;

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
      // Verify the email code
      await Base.auth.attemptSignUp(
        strategy: clerk.Strategy.emailCode,
        code: token,
      );

      if (Base.auth.isSignedIn) {
        // Sign-up complete — call /activate to get user identity
        await Base.resolveIdentity();
        // UserBloc will pick up the emission and transition to UserReady
      } else {
        // Sign-up has missing requirements (e.g. password) —
        // navigate to password setup to complete it.
        if (!mounted) return;
        context.router.replace(PasswordSetupRoute());
        return;
      }
    } on clerk.ClerkError catch (e, t) {
      log.warning('Error verifying OTP', e, t);
      if (!mounted) return;
      setState(() {
        _errorMessage = _clerkErrorMessage(e);
        _isLoading = false;
      });
    } on NetworkException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to connect. Please check your internet.';
        _isLoading = false;
      });
    } catch (e, t) {
      log.warning('Error verifying OTP', e, t);
      _showGenericError(e, t);
    }
  }

  Future<void> _handleResendCode() async {
    setState(() {
      _otpResetCounter++;
      _otpController.clear();
    });
    // Reset the client to clear the stale sign-up state, otherwise
    // attemptSignUp won't re-prepare verification for the same email.
    await Base.auth.resetClient();
    await _handleSignUp();
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
                  key: ValueKey(_otpResetCounter),
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
                  focusNode: _emailFocusNode,
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
                            onPress:
                                _isLoading ? null : _handlePasswordReset,
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
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          _emailFocusNode.requestFocus();
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

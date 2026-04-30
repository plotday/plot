import 'dart:async';
import 'package:auto_route/auto_route.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/router.dart' show PasswordSetupRoute;
import 'package:plot/api/network_exception.dart';
import 'package:plot/auth/auth_service.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/base.dart';
import 'logging.dart';

@RoutePage()
class EmailSignInPage extends StatefulWidget {
  const EmailSignInPage({this.returnTo, this.email, super.key});

  final String? returnTo;
  final String? email;

  @override
  State<EmailSignInPage> createState() => _EmailSignInPageState();
}

enum _AuthMode { signIn, signUp, otpSent, secondFactor }

class _EmailSignInPageState extends State<EmailSignInPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _otpController = FOtpController();
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
    context.showToast(
      message: 'Something went wrong. Please try again.',
      isError: true,
    );
    setState(() {
      _isLoading = false;
    });
  }

  String _authErrorMessage(AuthError e) {
    // For server errors, the human-readable message is in .argument
    // (.message contains a raw '{arg}' template).
    if (e.argument != null) return e.argument!;
    return e.message;
  }

  Future<void> _handleSignIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty) {
      context.showToast(
        message: 'Please enter your email address',
        isError: true,
      );
      return;
    }

    if (password.isEmpty) {
      context.showToast(
        message: 'Please enter your password',
        isError: true,
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      await Future(() async {
        if (Base.auth.isSignedIn) {
          // Already signed in (e.g. from a previous attempt that completed
          // Clerk auth but failed during /activate). Just resolve identity.
          await Base.resolveIdentity();
          return;
        }

        // Two-step sign-in flow:
        // 1. Identify with email
        await Base.auth.attemptSignIn(
          strategy: AuthStrategy.emailAddress,
          identifier: email,
        );
        // 2. Authenticate with password
        await Base.auth.attemptSignIn(
          strategy: AuthStrategy.password,
          password: password,
        );

        // Check if second factor is required (e.g. untrusted device)
        if (Base.auth.needsSecondFactor) {
          await Base.auth.prepareSecondFactor();
          if (!mounted) return;
          setState(() {
            _mode = _AuthMode.secondFactor;
            _isLoading = false;
          });
          return;
        }

        // Call /activate to get user identity
        await Base.resolveIdentity();
        // UserBloc will pick up the emission and transition to UserReady
      }).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      if (!mounted) return;
      context.showToast(
        message: 'Sign-in is taking too long. Please try again.',
        isError: true,
      );
      setState(() {
        _isLoading = false;
      });
    } on AuthError catch (e, t) {
      log.warning('Error signing in with password', e, t);
      if (!mounted) return;
      context.showToast(message: _authErrorMessage(e), isError: true);
      setState(() {
        _isLoading = false;
      });
    } on NetworkException {
      if (!mounted) return;
      context.showToast(
        message: 'Unable to connect. Please check your internet.',
        isError: true,
      );
      setState(() {
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
      context.showToast(
        message: 'Please enter your email address',
        isError: true,
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // Start sign-up flow — Clerk sends the email code
      await Base.auth.attemptSignUp(
        strategy: AuthStrategy.emailCode,
        emailAddress: email,
      ).timeout(const Duration(seconds: 15));
      setState(() {
        _mode = _AuthMode.otpSent;
        _isLoading = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      context.showToast(
        message: 'Sign-up is taking too long. Please try again.',
        isError: true,
      );
      setState(() {
        _isLoading = false;
      });
    } on AuthError catch (e, t) {
      log.warning('Error sending signup OTP', e, t);
      if (!mounted) return;
      context.showToast(message: _authErrorMessage(e), isError: true);
      setState(() {
        _isLoading = false;
      });
    } on NetworkException {
      if (!mounted) return;
      context.showToast(
        message: 'Unable to connect. Please check your internet.',
        isError: true,
      );
      setState(() {
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
      context.showToast(
        message: 'Please enter the verification code',
        isError: true,
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      await Future(() async {
        // Verify the email code
        await Base.auth.attemptSignUp(
          strategy: AuthStrategy.emailCode,
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
      }).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      if (!mounted) return;
      context.showToast(
        message: 'Verification is taking too long. Please try again.',
        isError: true,
      );
      setState(() {
        _isLoading = false;
      });
    } on AuthError catch (e, t) {
      log.warning('Error verifying OTP', e, t);
      if (!mounted) return;
      context.showToast(message: _authErrorMessage(e), isError: true);
      setState(() {
        _isLoading = false;
      });
    } on NetworkException {
      if (!mounted) return;
      context.showToast(
        message: 'Unable to connect. Please check your internet.',
        isError: true,
      );
      setState(() {
        _isLoading = false;
      });
    } catch (e, t) {
      log.warning('Error verifying OTP', e, t);
      _showGenericError(e, t);
    }
  }

  Future<void> _handleVerifySecondFactor() async {
    if (_isLoading) return;

    final code = _otpController.text.trim();

    if (code.isEmpty) {
      context.showToast(
        message: 'Please enter the verification code',
        isError: true,
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      await Future(() async {
        await Base.auth.attemptSecondFactor(code: code);

        // Call /activate to get user identity
        await Base.resolveIdentity();
        // UserBloc will pick up the emission and transition to UserReady
      }).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      if (!mounted) return;
      context.showToast(
        message: 'Verification is taking too long. Please try again.',
        isError: true,
      );
      setState(() {
        _isLoading = false;
      });
    } on AuthError catch (e, t) {
      log.warning('Error verifying second factor', e, t);
      if (!mounted) return;
      context.showToast(message: _authErrorMessage(e), isError: true);
      setState(() {
        _isLoading = false;
      });
    } on NetworkException {
      if (!mounted) return;
      context.showToast(
        message: 'Unable to connect. Please check your internet.',
        isError: true,
      );
      setState(() {
        _isLoading = false;
      });
    } catch (e, t) {
      log.warning('Error verifying second factor', e, t);
      _showGenericError(e, t);
    }
  }

  Future<void> _handleResendSecondFactor() async {
    setState(() {
      _otpResetCounter++;
      _otpController.clear();
      _isLoading = true;
    });

    try {
      await Base.auth.prepareSecondFactor();
      if (!mounted) return;
      setState(() => _isLoading = false);
    } on AuthError catch (e, t) {
      log.warning('Error resending second factor code', e, t);
      if (!mounted) return;
      context.showToast(message: _authErrorMessage(e), isError: true);
      setState(() {
        _isLoading = false;
      });
    } catch (e, t) {
      log.warning('Error resending second factor code', e, t);
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
                switch (_mode) {
                  _AuthMode.signUp => 'Create your account',
                  _AuthMode.secondFactor => 'Verify your identity',
                  _ => 'Sign in to Plot',
                },
                style: context.theme.typography.xl.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),

              // Second factor verification code entry
              if (_mode == _AuthMode.secondFactor) ...[
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

                Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(
                      opacity: _isLoading ? 0.3 : 1.0,
                      child: Column(
                        spacing: 8,
                        children: [
                          Text(
                            'Enter the 6-digit code from your email:',
                            style: context.theme.typography.md,
                            textAlign: TextAlign.center,
                          ),
                          FOtpField(
                            key: ValueKey('sf_$_otpResetCounter'),
                            control: FOtpFieldControl.managed(
                              controller: _otpController,
                              onChange: (value) {
                                if (value.text.length == 6) {
                                  FocusManager.instance.primaryFocus
                                      ?.unfocus();
                                  _handleVerifySecondFactor();
                                }
                              },
                            ),
                            autofocus: true,
                          ),
                        ],
                      ),
                    ),
                    if (_isLoading) const Spinner.message('Verifying...'),
                  ],
                ),

                const SizedBox(height: 8),

                // Resend and cancel buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FButton(
                      onPress:
                          _isLoading ? null : _handleResendSecondFactor,
                      variant: FButtonVariant.ghost,
                      child: const Text('Resend code'),
                    ),
                    const SizedBox(width: 8),
                    const Text('•'),
                    const SizedBox(width: 8),
                    FButton(
                      onPress: () {
                        setState(() {
                          _mode = _AuthMode.signIn;
                          _otpController.clear();
                        });
                      },
                      variant: FButtonVariant.ghost,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),

              // OTP sent confirmation with code entry (sign-up flow)
              ] else if (_mode == _AuthMode.otpSent) ...[
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

                Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(
                      opacity: _isLoading ? 0.3 : 1.0,
                      child: Column(
                        spacing: 8,
                        children: [
                          Text(
                            'Enter the 6-digit code from your email:',
                            style: context.theme.typography.md,
                            textAlign: TextAlign.center,
                          ),
                          FOtpField(
                            key: ValueKey(_otpResetCounter),
                            control: FOtpFieldControl.managed(
                              controller: _otpController,
                              onChange: (value) {
                                if (value.text.length == 6) {
                                  FocusManager.instance.primaryFocus
                                      ?.unfocus();
                                  _handleVerifyOtp();
                                }
                              },
                            ),
                            autofocus: true,
                          ),
                        ],
                      ),
                    ),
                    if (_isLoading) const Spinner.message('Verifying...'),
                  ],
                ),

                const SizedBox(height: 8),

                // Resend and try different email buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FButton(
                      onPress: _isLoading ? null : _handleResendCode,
                      variant: FButtonVariant.ghost,
                      child: const Text('Resend code'),
                    ),
                    const SizedBox(width: 8),
                    const Text('•'),
                    const SizedBox(width: 8),
                    FButton(
                      onPress: () {
                        setState(() {
                          _mode = _AuthMode.signIn;
                          _otpController.clear();
                        });
                      },
                      variant: FButtonVariant.ghost,
                      child: const Text('Different email'),
                    ),
                  ],
                ),
              ] else ...[
                // Email field
                AutofillGroup(
                  child: Column(
                    spacing: 8,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FTextField(
                        focusNode: _emailFocusNode,
                        control: .managed(controller: _emailController),
                        hint: 'your@email.com',
                        label: const Text('Email'),
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        autofocus: true,
                        autocorrect: false,
                        onSubmit: (_) => _mode == _AuthMode.signUp
                            ? _handleSignUp()
                            : _handleSignIn(),
                      ),

                      // Password field (only in sign-in mode)
                      if (_mode == _AuthMode.signIn)
                        FTextField(
                          control: .managed(controller: _passwordController),
                          hint: 'Enter your password',
                          label: const Text('Password'),
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          onSubmit: (_) => _handleSignIn(),
                        ),
                    ],
                  ),
                ),

                if (_mode == _AuthMode.signIn) ...[
                  Column(
                    spacing: 2,
                    children: [
                      // Forgot password link
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          FButton(
                            onPress:
                                _isLoading ? null : _handlePasswordReset,
                            variant: FButtonVariant.ghost,
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
                                    });
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          _emailFocusNode.requestFocus();
                                        });
                                  },
                            variant: FButtonVariant.ghost,
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
                    variant: FButtonVariant.primary,
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
                  variant: FButtonVariant.ghost,
                  child: const Text('Use another sign-in method'),
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

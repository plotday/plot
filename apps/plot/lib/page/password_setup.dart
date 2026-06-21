import 'package:auto_route/auto_route.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/auth/auth_service.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/base.dart';
import 'logging.dart';

@RoutePage()
class PasswordSetupPage extends StatefulWidget {
  const PasswordSetupPage({super.key});

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
  void dispose() {
    _nameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
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
      // Split name into first/last for Clerk
      final parts = name.split(' ');
      final firstName = parts.first;
      final lastName = parts.length > 1 ? parts.sublist(1).join(' ') : null;

      if (Base.auth.isSignedIn) {
        // Clerk's instance treated the email code alone as sufficient to
        // create the session, so the user is signed in but has no name or
        // password set. Apply both directly to the existing user.
        await Base.auth.updateUser(firstName: firstName, lastName: lastName);
        await Base.auth.setUserPassword(password: password);
      } else {
        // Update the pending sign-up with password and name.
        // Once all requirements are met, Clerk creates a session.
        await Base.auth.attemptSignUp(
          strategy: AuthStrategy.password,
          password: password,
          passwordConfirmation: confirmPassword,
          firstName: firstName,
          lastName: lastName,
        );

        if (!Base.auth.isSignedIn) {
          throw Exception(
            'Sign-up incomplete after setting password. '
            'Missing: ${Base.auth.signUpMissingFields}',
          );
        }
      }

      // Call /activate to get user identity, retrying transient backend
      // stalls so a first-time sign-up isn't failed by a brief burst.
      await Base.resolveIdentityResilient();
      // UserBloc will pick up the emission and transition to UserReady
    } on AuthError catch (e, t) {
      log.warning('Error completing sign-up', e, t);
      if (!mounted) return;
      setState(() {
        _errorMessage = e.argument ?? e.toString();
        _isLoading = false;
      });
    } on NetworkException {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to connect. Please check your internet.';
        _isLoading = false;
      });
    } catch (e, t) {
      log.warning('Error completing sign-up', e, t);
      Tracker.captureException(e, t);
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Something went wrong. Please try again.';
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

              AutofillGroup(
                child: Column(
                  spacing: 16,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FTextField(
                      builder: fieldSelectionBuilder,
                      control: .managed(controller: _nameController),
                      hint: 'Enter your name',
                      label: const Text('Name'),
                      autofillHints: const [AutofillHints.name],
                      autofocus: true,
                      onSubmit: (_) => _handleSubmit(),
                    ),

                    FTextField(
                      builder: fieldSelectionBuilder,
                      control: .managed(controller: _passwordController),
                      hint: 'Enter your password',
                      label: const Text('Password'),
                      obscureText: true,
                      autofillHints: const [AutofillHints.newPassword],
                      onSubmit: (_) => _handleSubmit(),
                    ),

                    FTextField(
                      builder: fieldSelectionBuilder,
                      control: .managed(controller: _confirmPasswordController),
                      hint: 'Re-enter your password',
                      label: const Text('Confirm Password'),
                      obscureText: true,
                      autofillHints: const [AutofillHints.newPassword],
                      onSubmit: (_) => _handleSubmit(),
                    ),
                  ],
                ),
              ),

              SizedBox(
                height: 44,
                child: FButton(
                  onPress: _isLoading ? null : _handleSubmit,
                  variant: FButtonVariant.primary,
                  child: _isLoading
                      ? const Spinner()
                      : const Text('Create Account'),
                ),
              ),

              if (_errorMessage != null) ...[
                FAlert(
                  variant: FAlertVariant.destructive,
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

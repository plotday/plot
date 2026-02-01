import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:auto_route/auto_route.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/base.dart';
import 'package:plot/state/user.dart';
import 'package:plot/router.dart' show EmailSignInRoute;
import 'package:plot/page/invite.dart';
import 'package:plot/page/loading.dart';
import 'logging.dart';

@RoutePage()
class SignInPage extends StatefulWidget {
  const SignInPage({this.returnTo, super.key});

  final String? returnTo;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  String? _errorMessage;
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const LoadingPage(message: 'Plotting your success…');
    }

    return Scaffold(
      center: true,
      body: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            spacing: 16,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Center(
                child: SvgPicture.asset(
                  "assets/p.svg",
                  width: 120,
                  height: 120,
                ),
              ),
              Text(
                PendingInvite.token != null
                    ? "You've been invited to collaborate on Plot. Sign up or sign in to continue."
                    : 'Sign in to make progress on your priorities',
                textAlign: TextAlign.center,
                style: context.theme.typography.base,
              ),
              const SizedBox(height: 8),

              // OAuth buttons
              AuthButton.authenticate(
                provider: AuthProvider.google,
                autoSignIn: false,
                onAuth: ({required idToken, accessToken}) async {
                  if (mounted) {
                    setState(() {
                      _errorMessage = null;
                      _isLoading = true;
                    });
                  }

                  try {
                    await Base.client.auth.signInWithIdToken(
                      provider: OAuthProvider.google,
                      idToken: idToken,
                      accessToken: accessToken,
                    );

                    // Clear password setup flag for OAuth sign-ins
                    // (they already have a password via OAuth provider)
                    if (context.mounted) {
                      await context
                          .read<UserBloc>()
                          .clearPasswordSetupRequired();
                    }
                  } on AuthException catch (e, t) {
                    log.warning('Error signing into Google', e, t);
                    if (!mounted) return;
                    setState(() {
                      _errorMessage = e.message;
                      _isLoading = false;
                    });
                  }
                },
                onError: (error) {
                  if (mounted) {
                    setState(() {
                      _errorMessage = error;
                    });
                  }
                },
              ),

              AuthButton.authenticate(
                provider: AuthProvider.apple,
                autoSignIn: false,
                onAuth: ({required idToken, accessToken}) async {
                  if (mounted) {
                    setState(() {
                      _errorMessage = null;
                      _isLoading = true;
                    });
                  }

                  try {
                    await Base.client.auth.signInWithIdToken(
                      provider: OAuthProvider.apple,
                      idToken: idToken,
                      accessToken: accessToken,
                    );

                    // Clear password setup flag for OAuth sign-ins
                    // (they already have a password via OAuth provider)
                    if (context.mounted) {
                      await context
                          .read<UserBloc>()
                          .clearPasswordSetupRequired();
                    }
                  } on AuthException catch (e, t) {
                    log.warning('Error signing into Apple', e, t);
                    if (!mounted) return;
                    setState(() {
                      _errorMessage = e.message;
                      _isLoading = false;
                    });
                  }
                },
                onError: (error) {
                  if (mounted) {
                    setState(() {
                      _errorMessage = error;
                    });
                  }
                },
              ),

              // Continue with email button
              FButton(
                onPress: () {
                  context.router.navigate(
                    EmailSignInRoute(returnTo: widget.returnTo),
                  );
                },
                style: FButtonStyle.secondary(),
                prefix: FaIcon(
                  FontAwesomeIcons.envelope,
                  color: context.theme.colors.foreground,
                ),
                mainAxisSize: .min,
                child: Text(
                  'Continue with email',
                  style: context.theme.typography.base.copyWith(
                    color: context.theme.colors.foreground,
                    height: 1,
                  ),
                ),
              ),

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

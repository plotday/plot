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
import 'package:logging/logging.dart';
import 'logging.dart';

@RoutePage()
class SignInPage extends StatefulWidget {
  const SignInPage({this.returnTo, this.onSignIn, super.key});

  final String? returnTo;
  final void Function()? onSignIn;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    return BlocListener<UserBloc, UserState>(
      listener: (context, state) {
        if (state is UserReady && widget.onSignIn != null) {
          Logger(
            'plot.route',
          ).info('SignInPage: UserReady detected, calling onSignIn callback');
          widget.onSignIn!();
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
                Center(
                  child: SvgPicture.asset(
                    "assets/p.svg",
                    width: 120,
                    height: 120,
                  ),
                ),
                Text(
                  'Sign in to make progress on your priorities',
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
                  prefix: const FaIcon(FontAwesomeIcons.envelope, size: 18),
                  child: const Text('Continue with email'),
                ),

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

                const SizedBox(height: 16),
                const TermsAgreement(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

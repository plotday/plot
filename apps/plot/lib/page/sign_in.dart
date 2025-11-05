import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:auto_route/auto_route.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/base.dart';
import 'package:plot/state/user.dart';
import 'package:plot/router.dart' show InvitationRoute;
import 'logging.dart';

@RoutePage()
class SignInPage extends StatefulWidget {
  const SignInPage({this.returnTo, this.signOut = false, super.key});

  final String? returnTo;
  final bool signOut;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  String? _errorMessage;

  @override
  void initState() {
    if (widget.signOut) {
      Future.microtask(() async {
        await Base.client.auth.signOut();
      });
    }
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<UserBloc, UserState>(
      listener: (context, state) {
        // Navigate when user is ready (Store.init has completed)
        if (state is UserReady) {
          context.router.navigatePath(widget.returnTo ?? '/');
        } else if (state is UserWaitlisted) {
          // Navigate to invitation page for waitlisted users
          context.router.navigate(const InvitationRoute());
        }
      },
      child: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 400),
            child: Column(
              spacing: 16,
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SvgPicture.asset("assets/p.svg", width: 120, height: 120),
                Text(
                  'Sign in to make progress on your priorities',
                  textAlign: TextAlign.center,
                ),
                AuthButton.authenticate(
                  provider: AuthProvider.google,
                  autoSignIn: false,
                  onAuth: ({required idToken, accessToken}) async {
                    // Clear any previous error when attempting new login
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
                DefaultTextStyle(
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    color: Color(0xFF6B7280),
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(
                          text: 'By signing in, you agree to the ',
                        ),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: HoverableLink(
                            text: 'Terms of Service',
                            uri: Uri.parse('https://plot.day/terms'),
                          ),
                        ),
                        const TextSpan(text: ' and '),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: HoverableLink(
                            text: 'Privacy Policy',
                            uri: Uri.parse('https://plot.day/privacy'),
                          ),
                        ),
                        const TextSpan(text: '.'),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

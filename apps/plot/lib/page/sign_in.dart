import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:auto_route/auto_route.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/base.dart';
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
  bool? _signedIn;
  String? _errorMessage;

  StreamSubscription<User?>? _userSubscription;

  @override
  void initState() {
    if (widget.signOut) {
      Future.microtask(() async {
        await Base.client.auth.signOut();
        if (!mounted) return;
        listen();
      });
    } else {
      listen();
    }
    super.initState();
  }

  void listen() {
    _userSubscription = Base.user.listen((user) {
      setState(() {
        _signedIn = user != null;
      });

      // Redirect to return path or home after successful sign-in
      if (user != null && mounted) {
        context.router.navigatePath(widget.returnTo ?? '/');
      }
    });
  }

  @override
  void dispose() {
    _userSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_signedIn == null) {
      return const Scaffold(body: Center(child: Spinner()));
    }

    return Scaffold(
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
              Text.rich(
                TextSpan(
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF6B7280),
                  ),
                  children: [
                    const TextSpan(text: 'By signing in, you agree to the '),
                    WidgetSpan(
                      child: Link(
                        uri: Uri.parse('https://plot.day/terms'),
                        child: const Text(
                          'Terms of Service',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF3B82F6),
                          ),
                        ),
                      ),
                    ),
                    const TextSpan(text: ' and '),
                    WidgetSpan(
                      child: Link(
                        uri: Uri.parse('https://plot.day/privacy'),
                        child: const Text(
                          'Privacy Policy',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF3B82F6),
                          ),
                        ),
                      ),
                    ),
                    const TextSpan(text: '.'),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

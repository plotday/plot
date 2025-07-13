import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:auto_route/auto_route.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/base.dart';
import 'logging.dart';

@RoutePage()
class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  bool? _signedIn;

  late final StreamSubscription<User?> _userSubscription;

  @override
  void initState() {
    _userSubscription = Base.user.listen((user) {
      setState(() {
        _signedIn = user != null;
      });
    });
    super.initState();
  }

  @override
  void dispose() {
    _userSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_signedIn == null) {
      return const Scaffold(body: Center(child: Spinner()));
    }

    return Scaffold(
      body: Center(
        child: AuthButton(
          onSignIn: (auth) async {
            if (auth.idToken == null) throw Exception('No idToken');
            try {
              await Base.client.auth.signInWithIdToken(
                provider: OAuthProvider.google,
                idToken: auth.idToken!,
                accessToken: auth.accessToken,
              );
            } on AuthException catch (e, t) {
              log.warning('Error signing into Google', e, t);
              if (!context.mounted) return;
              Alert.show(context, e.message);
            }
          },
        ),
      ),
    );
  }
}

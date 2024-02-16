import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'auth_button.dart';

final supabase = Supabase.instance.client;

class SignInPage extends StatefulWidget {
  const SignInPage({super.key, this.builder});

  final Widget Function(BuildContext)? builder;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  bool? _signedIn;

  late final StreamSubscription _authSubscription;

  @override
  void initState() {
    _initSupabase();
    super.initState();
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    super.dispose();
  }

  void _initSupabase() {
    _authSubscription = supabase.auth.onAuthStateChange.listen((data) {
      switch (data.event) {
        case AuthChangeEvent.initialSession:
          setState(() {
            _signedIn = data.session?.accessToken != null;
          });
          break;
        case AuthChangeEvent.signedIn:
          setState(() {
            _signedIn = true;
          });
          break;
        case AuthChangeEvent.signedOut:
          setState(() {
            _signedIn = false;
          });
          break;
        default:
          break;
      }
      if (data.session?.user == null) {
        Sentry.configureScope((scope) => scope.setUser(null));
      } else {
        Sentry.configureScope(
          (scope) => scope.setUser(SentryUser(
            id: data.session!.user.id,
            email: data.session!.user.email,
          )),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_signedIn == null) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_signedIn == true && widget.builder != null) {
      return widget.builder!(context);
    }

    return Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('Plot'),
        ),
        body: Center(
          child: AuthButton(
            onSignIn: (auth) async {
              if (auth.idToken == null) return;
              supabase.auth.signInWithIdToken(
                provider: OAuthProvider.google,
                idToken: auth.idToken!,
                accessToken: auth.accessToken,
              );
            },
          ),
        ));
  }
}

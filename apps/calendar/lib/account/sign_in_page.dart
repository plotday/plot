import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sign_in_widget.dart';

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
            _signedIn = supabase.auth.currentSession?.accessToken != null;
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
          child: SignInWidget(
            onSignIn: (auth) async {
              supabase.auth.signInWithIdToken(
                provider: OAuthProvider.google,
                idToken: auth.idToken,
                accessToken: auth.accessToken,
              );
            },
          ),
        ));
  }
}

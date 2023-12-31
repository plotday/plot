import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../env.dart';
import 'google_sign_in_button.dart';

final supabase = Supabase.instance.client;

class SignInPage extends StatefulWidget {
  const SignInPage({super.key, this.child});

  final Widget? child;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  bool? _signedIn;

  late final GoogleSignIn _googleSignIn;
  late final StreamSubscription _authSubscription;

  @override
  void initState() {
    _initSupabase();
    _initGoogle();
    super.initState();
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    _googleSignIn.disconnect();
    super.dispose();
  }

  void _initSupabase() {
    _authSubscription = supabase.auth.onAuthStateChange.listen((data) {
      switch (data.event) {
        case AuthChangeEvent.initialSession:
          setState(() {
            _signedIn = supabase.auth.currentSession?.accessToken != null;
            if (_signedIn == false && kIsWeb) {
              _googleSignIn.signInSilently();
            }
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

  void _initGoogle() {
    late final String? clientId;
    String? serverClientId;
    if (kIsWeb) {
      clientId = Env.googleClientId;
    } else if (Platform.isAndroid) {
      clientId = Env.googleAndroidClientId;
      serverClientId = Env.googleClientId;
    } else if (Platform.isIOS || Platform.isMacOS) {
      clientId = Env.googleIosClientId;
      serverClientId = Env.googleClientId;
    } else {
      clientId = Env.googleClientId;
    }
    _googleSignIn = GoogleSignIn(
        clientId: clientId, serverClientId: serverClientId, scopes: ['email']);

    _googleSignIn.onCurrentUserChanged
        .listen((GoogleSignInAccount? account) async {
      if (account == null) return;

      final googleAuth = await account.authentication;
      final accessToken = googleAuth.accessToken;
      final idToken = googleAuth.idToken;

      if (idToken == null) {
        throw 'No ID Token found.';
      }

      supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );
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
    if (_signedIn == true && widget.child != null) {
      return widget.child!;
    }

    return Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('Plot'),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: buildGoogleSignInButton(onPressed: () async {
              try {
                await _googleSignIn.signIn();
              } on String catch (message) {
                SnackBar(
                  content: Text(message),
                  backgroundColor: Theme.of(context).colorScheme.error,
                );
              }
            }),
          ),
        ));
  }
}

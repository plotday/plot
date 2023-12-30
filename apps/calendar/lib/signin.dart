import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'env.dart';

final supabase = Supabase.instance.client;

class SigninWidget extends StatelessWidget {
  const SigninWidget({super.key});

  Future<AuthResponse> _googleSignIn() async {
    late final String? clientId;
    if (Platform.isAndroid) {
      clientId = Env.googleAndroidClientId;
    } else {
      clientId = Env.googleIosClientId;
    }
    final GoogleSignIn googleSignIn = GoogleSignIn(
        clientId: clientId,
        serverClientId: Env.googleClientId,
        scopes: ['email']);
    final googleUser = await googleSignIn.signIn();
    if (googleUser == null) {
      throw 'No user returned.';
    }
    final googleAuth = await googleUser.authentication;
    final accessToken = googleAuth.accessToken;
    final idToken = googleAuth.idToken;

    if (accessToken == null) {
      throw 'No Access Token found.';
    }
    if (idToken == null) {
      throw 'No ID Token found.';
    }

    return supabase.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: accessToken,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ElevatedButton(
        onPressed: () async {
          try {
            final response = await _googleSignIn();
          } catch (e) {}
        },
        child: const Text('Sign in with Google'),
      ),
    );
  }
}

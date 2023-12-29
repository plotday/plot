import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'env.dart';

final supabase = Supabase.instance.client;

class SigninWidget extends StatelessWidget {
  const SigninWidget({super.key});

  Future<AuthResponse> _googleSignIn() async {
    // Google sign in on Android will work without providing the Android
    // Client ID registered on Google Cloud.

    final GoogleSignIn googleSignIn = GoogleSignIn(
        clientId: Env.googleIosClientId,
        serverClientId: Env.googleClientId,
        scopes: ['email']);
    final googleUser = await googleSignIn.signIn();
    print('Signed in');
    print(googleUser);
    print((await googleUser?.authentication)?.idToken);
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
            print('Got response');
            print(response.toString());
          } catch (e) {
            print(e.toString());
          }
        },
        child: const Text('Sign in with Google'),
      ),
    );
  }
}

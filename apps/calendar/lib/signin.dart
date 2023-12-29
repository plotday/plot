import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

class SigninWidget extends StatelessWidget {
  const SigninWidget({super.key});

  Future<AuthResponse> _googleSignIn() async {
    const webClientId =
        '535301598151-k717hhbgqe9jfoko9epc8m8c1jeqp2s4.apps.googleusercontent.com';

    const iosClientId =
        '182233668590-os9virkdkeo83ara6js7k4ilvjc4dd94.apps.googleusercontent.com';

    // Google sign in on Android will work without providing the Android
    // Client ID registered on Google Cloud.

    final GoogleSignIn googleSignIn = GoogleSignIn(
        clientId: iosClientId, serverClientId: webClientId, scopes: ['email']);
    final googleUser = await googleSignIn.signIn();
    print('Signed in');
    print(googleUser);
    print(await googleSignIn.currentUser);
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

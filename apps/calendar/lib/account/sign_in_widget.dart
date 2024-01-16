import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../env.dart';
import 'google_sign_in_button.dart';

class ProviderAuth {
  ProviderAuth(this.accessToken, this.idToken, this.serverAuthCode);

  final String accessToken;
  final String idToken;
  final String? serverAuthCode;
}

class SignInWidget extends StatefulWidget {
  const SignInWidget({required this.onSignIn, super.key});

  final void Function(ProviderAuth providerAuth) onSignIn;

  @override
  State<SignInWidget> createState() => _SignInWidgetState();
}

class _SignInWidgetState extends State<SignInWidget> {
  late final GoogleSignIn _googleSignIn;

  @override
  void initState() {
    _initGoogle();
    super.initState();
  }

  @override
  void dispose() {
    _googleSignIn.disconnect();
    super.dispose();
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

      if (accessToken == null) {
        throw 'Missing access token';
      }
      if (idToken == null) {
        throw 'Missing ID token';
      }

      widget
          .onSignIn(ProviderAuth(accessToken, idToken, account.serverAuthCode));
    });
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: buildGoogleSignInButton(onPressed: () async {
        try {
          await _googleSignIn.signIn();
        } on String catch (message) {
          if (mounted) {
            SnackBar(
              content: Text(message),
              backgroundColor: Theme.of(context).colorScheme.error,
            );
          }
        }
      }),
    );
  }
}

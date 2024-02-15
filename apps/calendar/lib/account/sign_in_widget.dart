import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../env.dart';
import 'google_sign_in.dart';

class ProviderAuth {
  ProviderAuth(this.accessToken, this.idToken, this.serverAuthCode);

  final String? accessToken;
  final String idToken;
  final String? serverAuthCode;
}

class SignInWidget extends StatefulWidget {
  const SignInWidget(
      {required this.onSignIn,
      this.scopes = const ['email'],
      this.authorization = false,
      super.key});

  final void Function(ProviderAuth providerAuth) onSignIn;

  final List<String> scopes;
  final bool authorization;

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
    print("clientId: $clientId");
    print("serverClientId: $serverClientId");
    print("scopes: ${widget.scopes}");
    _googleSignIn = GoogleSignIn(
      clientId: clientId,
      serverClientId: serverClientId,
      scopes: widget.scopes,
      forceCodeForRefreshToken: widget.authorization,
    );

    _googleSignIn.onCurrentUserChanged
        .listen((GoogleSignInAccount? account) async {
      if (account == null) return;

      final googleAuth = await account.authentication;
      final accessToken = googleAuth.accessToken;
      final idToken = googleAuth.idToken;
      print("accessToken: $accessToken");
      print("idToken: $idToken");
      print("authCode: ${account.serverAuthCode}");

      if (idToken == null) {
        throw 'Missing ID token';
      }

      widget
          .onSignIn(ProviderAuth(accessToken, idToken, account.serverAuthCode));
      if (widget.authorization) _googleSignIn.signOut();
    });

    if (kIsWeb && !widget.authorization) {
      _googleSignIn.signInSilently();
    }
  }

  Future<void> onSignIn() async {
    try {
      if (widget.authorization) {
        print("here we go!");
        await _googleSignIn.requestScopes(widget.scopes);
        print("SAC: ${_googleSignIn.currentUser?.serverAuthCode}");
      } else {
        await _googleSignIn.signIn();
      }
    } on String catch (message) {
      if (mounted) {
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: widget.authorization
          ? ElevatedButton(
              onPressed: onSignIn,
              child: const Text("Authorize"),
            )
          : buildGoogleSignInButton(onPressed: onSignIn),
    );
  }
}

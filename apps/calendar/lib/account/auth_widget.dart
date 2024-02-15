import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../env.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

class ProviderAuth {
  ProviderAuth(this.code);

  final String code;
}

class AuthWidget extends StatelessWidget {
  const AuthWidget(
      {required this.onSignIn, this.scopes = const ['email'], super.key});

  final void Function(ProviderAuth providerAuth) onSignIn;

  final List<String> scopes;

  Future<void> startSignIn() async {
    const callbackUrlScheme = 'plot-auth';
    const callbackUrl = kIsWeb ? Env.authCallbackUrl : '$callbackUrlScheme:/';

    final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'response_type': 'code',
      'client_id': Env.googleClientId,
      'redirect_uri': callbackUrl,
      'scope': scopes.join(' '),
      'access_type': 'offline',
      'include_granted_scopes': 'true',
      'prompt': 'select_account',
    });

    // Present the dialog to the user
    final result = await FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: callbackUrlScheme,
    );

    final code = Uri.parse(result).queryParameters['code'];
    if (code != null) {
      onSignIn(ProviderAuth(code));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: startSignIn,
      child: const Text("Authorize"),
    );
  }
}

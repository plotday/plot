import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:social_login_buttons/social_login_buttons.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'package:plot/env.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/util/google_sign_in.dart';
import 'logging.dart';

class ProviderAuth {
  ProviderAuth({this.accessToken, this.idToken, this.code});

  final String? accessToken;
  final String? idToken;
  final String? code;
}

class AuthButton extends StatefulWidget {
  const AuthButton({required this.onSignIn, this.scopes, super.key});

  final Future<void> Function(ProviderAuth providerAuth) onSignIn;

  final List<String>? scopes;

  @override
  State<AuthButton> createState() => _AuthButtonState();
}

class _AuthButtonState extends State<AuthButton> {
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
    late final String clientId;
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
      clientId: clientId,
      serverClientId: serverClientId,
      scopes: widget.scopes ?? ['email'],
      forceCodeForRefreshToken: widget.scopes != null,
    );

    _googleSignIn.onCurrentUserChanged.listen((
      GoogleSignInAccount? account,
    ) async {
      if (account == null) return;

      final googleAuth = await account.authentication;
      final accessToken = googleAuth.accessToken;
      final idToken = googleAuth.idToken;
      final code = account.serverAuthCode;

      await widget.onSignIn(
        ProviderAuth(accessToken: accessToken, idToken: idToken, code: code),
      );
      _googleSignIn.signOut();
    });

    if (kIsWeb && widget.scopes == null) {
      _googleSignIn.signInSilently();
    }
  }

  Future<void> nativeAuth() async {
    try {
      if (await _googleSignIn.isSignedIn()) {
        await _googleSignIn.disconnect();
      }
      await _googleSignIn.signIn();
    } on String catch (message) {
      log.warning('Google sign-in failed: $message');
      if (mounted) {
        Alert.show(context, message);
      }
    } on Exception catch (e, t) {
      log.warning('Google sign-in failed', e, t);
      if (mounted) {
        Alert.show(context, e.toString());
      }
    }
  }

  Future<void> webAuth() async {
    if (widget.scopes == null) {
      throw 'Missing scopes';
    }

    const callbackUrlScheme = 'plot-auth';
    final callbackUrl = kIsWeb ? Env.authCallbackUrl : '$callbackUrlScheme:/';

    final args = {
      'response_type': 'code',
      'client_id': Env.googleClientId,
      'redirect_uri': callbackUrl,
      'scope': widget.scopes!.join(' '),
      'access_type': 'offline',
      'include_granted_scopes': 'true',
      'prompt': 'select_account consent',
    };
    final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', args);

    // Present the dialog to the user
    final result = await FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: callbackUrlScheme,
    );

    final code = Uri.parse(result).queryParameters['code'];
    if (code != null) {
      widget.onSignIn(ProviderAuth(code: code));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: kIsWeb && widget.scopes == null
          ? buildGoogleSignInButton()
          : SocialLoginButton(
              buttonType: SocialLoginButtonType.google,
              onPressed: kIsWeb ? webAuth : nativeAuth,
            ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:social_login_buttons/social_login_buttons.dart';

typedef HandleSignInFn = Future<void> Function();

Widget buildGoogleSignInButton({HandleSignInFn? onPressed}) {
  return SocialLoginButton(
    buttonType: SocialLoginButtonType.google,
    onPressed: onPressed,
  );
}

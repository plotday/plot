import 'package:flutter/material.dart';
import 'package:google_sign_in_web/web_only.dart';

typedef HandleSignInFn = Future<void> Function();

Widget buildGoogleSignInButton({HandleSignInFn? onPressed}) {
  return renderButton(
    configuration: GSIButtonConfiguration(
      theme: GSIButtonTheme.filledBlue,
    ),
  );
}

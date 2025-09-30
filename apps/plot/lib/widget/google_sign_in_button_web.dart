import 'package:flutter/widgets.dart';
import 'package:google_sign_in_web/web_only.dart';

typedef HandleSignInFn = Future<void> Function();

Widget buildGoogleSignInButton() {
  return renderButton(
    configuration: GSIButtonConfiguration(
      type: GSIButtonType.standard,
    ),
  );
}

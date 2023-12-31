import 'package:flutter/material.dart';
import 'package:google_sign_in_web/web_only.dart' as web;

typedef HandleSignInFn = Future<void> Function();

Widget buildGoogleSignInButton({HandleSignInFn? onPressed}) {
  return web.renderButton();
}

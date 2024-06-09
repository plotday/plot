import 'package:flutter/material.dart';

import 'package:plot/widget/auth_button.dart';
import 'package:plot/base.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Plot'),
      ),
      body: Center(
        child: AuthButton(
          onSignIn: (auth) async {
            if (auth.idToken == null) return;
            try {
              await base.auth.signInWithIdToken(
                provider: OAuthProvider.google,
                idToken: auth.idToken!,
                accessToken: auth.accessToken,
              );
            } on AuthException catch (e) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(e.message),
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
              );
            }
          },
        ),
      ),
    );
  }
}

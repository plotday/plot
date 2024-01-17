import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sign_in_widget.dart';

final supabase = Supabase.instance.client;

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            SignInWidget(
              onSignIn: (providerAuth) async {
                print("providerAuth: ${providerAuth.serverAuthCode}");
              },
              codeForRefreshToken: true,
              scopes: const [
                'calendar.events',
                'calendar.calendarlist.readonly',
                'offline'
              ],
            ),
            ElevatedButton(
                onPressed: () async {
                  try {
                    await supabase.auth.signOut();
                  } on AuthException catch (e) {
                    if (!context.mounted) return;
                    SnackBar(
                      content: Text(e.message),
                      backgroundColor: Theme.of(context).colorScheme.error,
                    );
                  }
                },
                child: const Text('Sign Out')),
          ],
        ),
      ),
    );
  }
}

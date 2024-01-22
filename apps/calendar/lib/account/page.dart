import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sign_in_widget.dart';
import 'account.dart';

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
                if (providerAuth.serverAuthCode == null) return;
                await Account.add(
                    AccountProvider.google, providerAuth.serverAuthCode!);
              },
              codeForRefreshToken: true,
              scopes: const [
                'https://www.googleapis.com/auth/calendar.events',
                'https://www.googleapis.com/auth/calendar.calendarlist.readonly',
              ],
              repeatable: true,
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

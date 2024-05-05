import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:plot/model/account.dart';
import 'package:plot/widget/auth_button.dart';

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
            AuthButton(
              onSignIn: (providerAuth) async {
                if (providerAuth.code != null) {
                  await Account.add(AccountProvider.google, providerAuth.code!);
                }
              },
              scopes: const [
                'openid',
                'profile',
                'https://www.googleapis.com/auth/calendar.events',
                'https://www.googleapis.com/auth/calendar.calendarlist.readonly',
              ],
            ),
            const SizedBox(height: 16),
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

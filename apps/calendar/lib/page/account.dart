import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/base.dart';
import 'package:plot/platform/widgets.dart';
import 'package:plot/state/accounts.dart';
import 'package:plot/model/account.dart';
import 'package:plot/widget/auth_button.dart';

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: 'Settings',
      body: BlocBuilder<AccountsBloc, AccountsState>(
        builder: (context, state) => ListView(
          children: [
            const Text("Accounts"),
            ...state.accounts.map((account) {
              return Text(account.email);
            }),
            AuthButton(
              onSignIn: (providerAuth) async {
                if (providerAuth.code == null) {
                  print("Missing auth code");
                  return;
                }
                await Account.add(AccountProvider.google, providerAuth.code!);
              },
              scopes: const [
                'openid',
                'profile',
                'https://www.googleapis.com/auth/calendar.events',
                'https://www.googleapis.com/auth/calendar.calendarlist.readonly',
              ],
            ),
            const SizedBox(height: 16),
            Button(
              onTap: () async {
                try {
                  await base.auth.signOut();
                } on AuthException catch (e) {
                  if (!context.mounted) return;
                  print("Sign out error: ${e.message}");
                  // SnackBar(
                  //   content: Text(e.message),
                  //   backgroundColor: Theme.of(context).colorScheme.error,
                  // );
                }
              },
              child: const Text('Sign Out'),
            ),
          ],
        ),
      ),
    );
  }
}

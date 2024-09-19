import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/base.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/state/accounts.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/auth_button.dart';

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: const Text('Settings'),
      body: BlocBuilder<AccountsBloc, AccountsState>(
        builder: (context, state) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Calendars"),
              const SizedBox(height: 8),
              ...state.accounts.expand(
                (account) => [
                  Text(account.account.email),
                  ...account.calendars.map(
                    (calendar) => Column(
                      children: [
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(calendar.name),
                            const SizedBox(width: 8),
                            Button(
                              child: calendar.enabled
                                  ? const Text('Re-sync')
                                  : const Text('Sync'),
                              onTap: () {
                                calendar.sync();
                              },
                            ),
                          ],
                        )
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text("Add Calendars"),
              const SizedBox(height: 8),
              AuthButton(
                onSignIn: (providerAuth) async {
                  if (providerAuth.code == null) {
                    print("Missing auth code");
                    return;
                  }
                  await Accounts.add(
                      AccountProvider.google, providerAuth.code!);
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
      ),
    );
  }
}

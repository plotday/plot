import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/state/accounts.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/auth_button.dart';

class CalendarSettingsPage extends StatelessWidget {
  const CalendarSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AccountsBloc, AccountsState>(
      builder: (context, state) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.accounts.isNotEmpty)
            ...state.accounts
                    .expand(
                      (account) => [
                        Text(account.email),
                        if (account.calendars != null)
                          ...account.calendars!.map(
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
                    )
                    .toList() +
                [const SizedBox(height: 16)],
          const Text("Add a calendar"),
          const SizedBox(height: 8),
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
        ],
      ),
    );
  }
}

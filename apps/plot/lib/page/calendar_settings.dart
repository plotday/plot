import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/state/accounts.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/command/command.dart';

class CalendarSettingsPage extends StatefulWidget {
  const CalendarSettingsPage({super.key});

  @override
  State<CalendarSettingsPage> createState() => CalendarSettingsPageState();
}

class CalendarSettingsPageState extends State<CalendarSettingsPage> {
  bool _loading = false;
  String? _error;

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
                                    Button(SyncCalendar(calendar)),
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
                setState(() {
                  _error = 'Authorization failed.';
                });
                return;
              }
              try {
                setState(() {
                  _loading = true;
                  _error = null;
                });
                await Account.add(AccountProvider.google, providerAuth.code!);
              } on Exception catch (e) {
                print(e);
                setState(() {
                  _error = 'Failed to sync.';
                });
              } finally {
                setState(() {
                  _loading = false;
                });
              }
            },
            scopes: const [
              'openid',
              'profile',
              'https://www.googleapis.com/auth/calendar.events',
              'https://www.googleapis.com/auth/calendar.calendarlist.readonly',
            ],
          ),
          const SizedBox(height: 8),
          if (_loading) const Spinner.message('Syncing calendar'),
          if (_error != null) Text(_error!),
        ],
      ),
    );
  }
}

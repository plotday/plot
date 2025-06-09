import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/state/accounts.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/command/command.dart';
import 'package:plot/command/calendar.dart';

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
      builder: (context, state) {
        final items = <Widget>[];
        
        // Add existing accounts and their calendars
        for (final account in state.accounts) {
          // Account header
          items.add(
            ListTile(
              title: account.email,
              style: ListTileStyle.header,
            ),
          );
          
          // Account calendars
          if (account.calendars != null) {
            for (final calendar in account.calendars!) {
              items.add(
                CalendarListTile(calendar: calendar),
              );
            }
          }
        }
        
        // Add calendar section
        items.add(
          ListTile(
            title: "Add a calendar",
            style: ListTileStyle.header,
          ),
        );
        
        items.add(
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                      await Account.add(
                        AccountProvider.google,
                        providerAuth.code!,
                      );
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
          ),
        );
        
        return ListView(
          children: items,
        );
      },
    );
  }
}

class CalendarListTile extends StatefulWidget {
  const CalendarListTile({required this.calendar, super.key});

  final Calendar calendar;

  @override
  State<CalendarListTile> createState() => _CalendarListTileState();
}

class _CalendarListTileState extends State<CalendarListTile> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Calendar>>(
      stream: Calendar.watch(),
      builder: (context, snapshot) {
        // Find the current calendar in the updated list
        final calendars = snapshot.data ?? [];
        final currentCalendar = calendars.firstWhere(
          (c) => c.id == widget.calendar.id,
          orElse: () => widget.calendar,
        );
        final isEnabled = currentCalendar.enabled;
        
        return _buildCalendarTile(context, currentCalendar, isEnabled);
      },
    );
  }

  Widget _buildCalendarTile(BuildContext context, Calendar calendar, bool isEnabled) {
    if (isEnabled) {
      // Enabled calendar - show priority
      return FutureBuilder<Priority?>(
        future: calendar.getPriority(),
        builder: (context, snapshot) {
          final priority = snapshot.data;
          return ListTile(
            title: calendar.name,
            body: priority != null 
                ? PriorityLabel(priority: priority)
                : Text(
                    'No priority set',
                    style: context.theme.typography.xs.copyWith(
                      color: context.colour.accent,
                    ),
                  ),
            trailingCommands: [
              SyncCalendar(calendar),
            ],
          );
        },
      );
    } else {
      // Disabled calendar - show plus icon
      return ListTile(
        title: calendar.name,
        body: Text(
          'Tap + to enable',
          style: context.theme.typography.xs.copyWith(
            color: context.colour.muted,
          ),
        ),
        trailingCommands: [
          EnableCalendar(calendar),
          SyncCalendar(calendar),
        ],
      );
    }
  }
}

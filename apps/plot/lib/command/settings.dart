import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;
import 'package:plot/base.dart';

import 'command.dart';
import 'package:plot/page/calendar_settings.dart';
import 'package:plot/store/store.dart';

class SettingsCommands extends Commands<void> {
  SettingsCommands()
    : super(
        groups: [
          StaticCommandGroup(
            title: 'Settings',
            commands: [CalendarSettings(), SignOut()],
          ),
        ],
        prompt: 'Settings',
      );
}

class ShowSettings extends ShowCommand<void> {
  ShowSettings()
    : super(
        title: 'Settings',
        commands: (context) => SettingsCommands(),
        shortcut: const SingleActivator(LogicalKeyboardKey.period, meta: true),
      );
}

class CalendarSettings extends Command {
  CalendarSettings()
    : super(
        title: 'Calendar Settings',
        description: 'Add calendars and change sync settings',
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return CommandPage(const CalendarSettingsPage());
  }
}

class SignOut extends Command {
  SignOut() : super(title: 'Sign Out');

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    try {
      await Base.client.auth.signOut();
    } on supa.AuthException catch (e) {
      print("Sign out error: ${e.message}");
      // if (context.mounted) {
      // SnackBar(
      //   content: Text(e.message),
      //   backgroundColor: Theme.of(context).colorScheme.error,
      // );
      // }
    }
    return null;
  }
}

class SyncCalendar extends Command {
  SyncCalendar(this.calendar)
    : super(title: calendar.enabled ? 'Re-sync' : 'Sync');

  final Calendar calendar;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await calendar.sync();
    return null;
  }
}

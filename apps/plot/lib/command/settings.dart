import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import 'package:plot/base.dart';
import 'package:plot/widget/icon.dart';
import 'command.dart';

final settingsCommands = StaticCommandGroup(
  title: 'Settings',
  commands: [ShowAllCalendarSettings(), SignOut()],
);

class ShowSettings extends ShowCommands<void> {
  ShowSettings()
    : super(
        title: 'Settings',
        icon: PlotIcon.settings,
        commands:
            (context) =>
                Commands<void>(groups: [settingsCommands], prompt: 'Settings'),
        // SettingsCommands(),
        shortcut: const SingleActivator(LogicalKeyboardKey.period, meta: true),
      );
}

class SignOut extends Command {
  SignOut() : super(title: 'Sign Out', icon: PlotIcon.signOut);

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

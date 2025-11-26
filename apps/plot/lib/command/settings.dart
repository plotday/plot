import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/analytics/analytics.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/base.dart';
import 'command.dart';
import 'logging.dart';

final appearanceCommands = StaticCommandGroup(
  title: 'Appearance',
  commands: [
    ChangeTheme(AppThemeMode.system),
    ChangeTheme(AppThemeMode.light),
    ChangeTheme(AppThemeMode.dark),
  ],
);

final settingsCommands = StaticCommandGroup(
  title: 'Settings',
  commands: [ChangeAppearance()],
);

final accountCommands = StaticCommandGroup(
  title: 'Account',
  commands: [SignOut()],
);

class ShowSettings extends ShowCommands {
  ShowSettings()
    : super(
        title: 'Settings',
        icon: PlotIcon.settings,
        commands: (context) => Future.value(
          Commands(groups: [settingsCommands], prompt: 'Settings'),
        ),
        shortcut: const SingleActivator(LogicalKeyboardKey.period, meta: true),
      );
}

class ChangeAppearance extends ShowCommands {
  ChangeAppearance()
    : super(
        title: 'Change Light/Dark Mode',
        icon: FontAwesomeIcons.sun,
        commands: (context) =>
            Future.value(Commands(groups: [appearanceCommands])),
      );
}

class SignOut extends Command {
  SignOut()
    : super(
        title: 'Sign Out',
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
        icon: PlotIcon.signOut,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await Base.client.auth.signOut();
      return CommandDone();
    } on supa.AuthException catch (e, t) {
      log.warning("Sign out failed", e, t);
      return CommandMessage('Sign out failed: ${e.message}', isError: true);
    }
  }
}

class ChangeTheme extends Command {
  ChangeTheme(this.themeMode)
    : super(
        title: _getTitle(themeMode),
        subtitle: _getSubtitle(themeMode),
        eventObject: EventObject.settings,
        eventAction: EventAction.updated,
        icon: _getIcon(themeMode),
      );

  final AppThemeMode themeMode;

  static String _getTitle(AppThemeMode mode) {
    return switch (mode) {
      AppThemeMode.system => 'System',
      AppThemeMode.light => 'Light',
      AppThemeMode.dark => 'Dark',
    };
  }

  static String _getSubtitle(AppThemeMode mode) {
    return switch (mode) {
      AppThemeMode.system => 'Follow system theme',
      AppThemeMode.light => 'Always use light theme',
      AppThemeMode.dark => 'Always use dark theme',
    };
  }

  static IconData _getIcon(AppThemeMode mode) {
    return switch (mode) {
      AppThemeMode.system => FontAwesomeIcons.circleHalfStroke,
      AppThemeMode.light => FontAwesomeIcons.sun,
      AppThemeMode.dark => FontAwesomeIcons.moon,
    };
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      context.read<ThemeBloc>().setThemeMode(themeMode);
      return const CommandDone();
    } catch (e, t) {
      log.warning("Change theme failed", e, t);
      return CommandMessage('Failed to change theme', isError: true);
    }
  }
}

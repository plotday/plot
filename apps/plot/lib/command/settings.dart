import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/app_info.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/select_modal.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/state/settings.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/platform.dart';
import 'command.dart';
import 'page_link.dart';
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
  title: 'App',
  shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
  commands: [
    ManageTwists(),
    CopyPageLink(), OpenCopiedPageLink(),
    ChangeAppearance(),
    // Only show Enter Behavior setting on devices with physical keyboards
    if (hasPhysicalKeyboard()) ChangeEnterBehavior(),
    CopyVersion(),
    SignOut(),
  ],
);

final signedOutSettingsCommands = StaticCommandGroup(
  title: 'App',
  commands: [ChangeAppearance(), CopyVersion()],
);

class ShowSettings extends ShowCommands {
  ShowSettings()
    : super(
        title: 'Settings',
        icon: PlotIcon.settings,
        commands: (context) => Future.value(
          Commands(groups: [settingsCommands], prompt: 'Settings'),
        ),
        shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
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

class ChangeEnterBehavior extends Command {
  ChangeEnterBehavior()
    : super(
        title: 'Change Enter Key Behavior',
        icon: FontAwesomeIcons.keyboard,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final modifierKey = defaultTargetPlatform == TargetPlatform.macOS
        ? 'Cmd'
        : 'Ctrl';
    final currentBehavior = context.read<SettingsBloc>().state.enterBehavior;

    final result = await SelectModal.open<EnterBehavior>(
      context,
      items: (search) async => [
        SelectGroup(
          title: 'Enter Key Behavior',
          items: [EnterBehavior.enterSubmits, EnterBehavior.enterNewline],
        ),
      ],
      itemBuilder: (behavior) {
        final title = behavior == EnterBehavior.enterSubmits
            ? 'Enter saves the note'
            : 'Enter adds a new line';
        final subtitle = behavior == EnterBehavior.enterSubmits
            ? 'Shift-Enter adds a new line and $modifierKey-Enter saves an action'
            : '$modifierKey-Enter saves the note';

        return Padding(
          padding: widgetPaddingSm,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: context.theme.typography.base.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: context.theme.typography.sm.copyWith(
                  color: context.theme.plotColors.muted,
                ),
              ),
            ],
          ),
        );
      },
      selectedValue: currentBehavior,
      prompt: 'Choose Enter key behavior',
    );

    if (context.mounted && result.present) {
      try {
        await context.read<SettingsBloc>().setEnterBehavior(result.value);
        return const CommandDone();
      } catch (e, t) {
        log.warning("Change enter behavior failed", e, t);
        return CommandMessage('Failed to change enter behavior', isError: true);
      }
    }

    return const CommandDone();
  }
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
      await Base.signOut();
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

class CopyVersion extends Command {
  CopyVersion()
    : super(
        title: 'Version',
        subtitle: AppInfo.versionString,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
        icon: FontAwesomeIcons.clipboard,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await Clipboard.setData(ClipboardData(text: AppInfo.versionString));
      return CommandMessage('Version copied to clipboard');
    } catch (e, t) {
      log.warning("Copy version failed", e, t);
      return CommandMessage('Failed to copy version', isError: true);
    }
  }
}

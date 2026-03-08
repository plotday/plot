import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:collection/collection.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/api/twist_permission.dart';
import 'package:plot/app_info.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/select_modal.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/state/settings.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
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
  shortcut: platformSingleActivator(LogicalKeyboardKey.comma),
  commands: [
    ManageConnections(),
    ManageTwists(),
    CopyPageLink(), OpenCopiedPageLink(),
    ChangeAppearance(),
    ChangeAiPreference(),
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
        commands: Commands(groups: [settingsCommands], prompt: 'Settings'),
        shortcut: platformSingleActivator(LogicalKeyboardKey.comma),
      );
}

class ChangeAppearance extends ShowCommands {
  ChangeAppearance()
    : super(
        title: 'Change Light/Dark Mode',
        icon: FontAwesomeIcons.sun,
        commands: Commands(groups: [appearanceCommands], prompt: 'Appearance'),
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
      itemBuilder: (behavior, _) {
        final title = behavior == EnterBehavior.enterSubmits
            ? 'Enter saves the note'
            : 'Enter adds a new line';
        final subtitle = behavior == EnterBehavior.enterSubmits
            ? 'Shift-Enter adds a new line and $modifierKey-Enter saves an action'
            : '$modifierKey-Enter saves the note';

        return Padding(
          padding: context.theme.spacing.paddingSm,
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
    } catch (e, t) {
      log.warning("Sign out failed", e, t);
      return CommandMessage('Sign out failed: $e', isError: true);
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

class ChangeAiPreference extends ShowForm {
  ChangeAiPreference()
    : super(
        title: 'AI Preferences',
        icon: FontAwesomeIcons.robot,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
        form: _buildForm,
      );

  static Future<FormData> _buildForm(BuildContext context) async {
    final currentValue = context.read<SettingsBloc>().state.aiEnabled;
    final showWarning = ValueNotifier(!currentValue);

    final toggle = FormToggle(
      key: 'aiEnabled',
      label: 'Enable AI Features',
      details:
          'AI is used for search, content analysis, and twist capabilities.',
      initialValue: currentValue,
    );
    toggle.addListener(() {
      showWarning.value = !toggle.getValue();
    });

    final warning = FormInfo(
      key: 'warning',
      builder: (context) {
        return ValueListenableBuilder<bool>(
          valueListenable: showWarning,
          builder: (context, show, _) {
            if (!show) return const SizedBox.shrink();
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.theme.spacing.lg,
              ),
              child: Text(
                'Twists that require AI will be archived.',
                style: context.theme.typography.sm.copyWith(
                  color: context.theme.colors.destructive,
                ),
              ),
            );
          },
        );
      },
    );

    return FormData(
      title: 'AI Preferences',
      groups: [
        StaticFormGroup(
          items: [
            toggle,
            warning,
            FormButton(
              key: 'save',
              buildCommand: (values) => _SaveAiPreference(
                aiEnabled: values['aiEnabled'] as bool,
                previousValue: currentValue,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SaveAiPreference extends Command {
  _SaveAiPreference({required this.aiEnabled, required this.previousValue})
    : super(
        title: 'Save',
        eventObject: EventObject.settings,
        eventAction: EventAction.updated,
      );

  final bool aiEnabled;
  final bool previousValue;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await context.read<SettingsBloc>().setAiEnabled(aiEnabled);

      // If toggling AI off, archive twists that require AI
      if (previousValue && !aiEnabled) {
        final archived = await _archiveAiRequiringTwists();
        if (archived > 0) {
          return CommandMessage(
            'AI disabled. $archived twist${archived == 1 ? '' : 's'} archived.',
          );
        }
      }

      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to save AI preference', e, t);
      return CommandMessage('Failed to save AI preference', isError: true);
    }
  }

  /// Archive installed twists that require AI.
  /// Returns the number of twists archived.
  Future<int> _archiveAiRequiringTwists() async {
    int archived = 0;

    // Get all priorities to check their twists
    final priorities = await Priority.get(order: PriorityOrder.nested);

    for (final priority in priorities) {
      try {
        final twists = await TwistApi.getAllTwists(priority);
        // Find twists that require AI (have _ai_required in permissions)
        final aiTwists = twists.where((t) => t.permissions?.hasPermission(
          'ai', 'prompt', PermissionFlag.use,
        ) == true);

        // Get active local priority_twists for this priority to find IDs
        final localTwists = await PriorityTwist.get(
          priorityId: priority.id,
          includeAncestors: false,
          archived: false,
        );

        for (final aiTwist in aiTwists) {
          // Find matching local priority_twist
          final localTwist = localTwists.where(
            (lt) => lt.twistId.toString() == aiTwist.id,
          ).firstOrNull;

          if (localTwist != null) {
            await TwistApi.archiveAndRemoveTwist(localTwist.id.toString());
            await Store.get.save(
              PriorityTwist.table,
              localTwist.copyWith(
                archivedAt: Value(DateTime.now()),
                updatedAt: DateTime.now(),
              ),
              PriorityTwistsBase(),
            );
            archived++;
          }
        }
      } catch (e) {
        log.warning('Failed to check twists for priority ${priority.title}', e);
      }
    }

    return archived;
  }
}

class ShowOfflineInfo extends ShowPage {
  ShowOfflineInfo()
    : super(
        title: 'Offline',
        icon: PlotIcon.offline,
        builder: (context) => _OfflineInfoContent(),
      );
}

class _OfflineInfoContent extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: context.theme.spacing.padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Unable to reach Plot servers',
            style: context.theme.typography.lg.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Check your network connection and try again. If you\'re online, try signing in again.',
            style: context.theme.typography.base.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FButton(
                onPress: () => Modal.pop<CommandReturn>(
                  context,
                  Value(const CommandDone()),
                ),
                style: FButtonStyle.secondary(),
                child: const Text('Close'),
              ),
              const SizedBox(width: 12),
              FButton(
                onPress: () async {
                  Modal.pop<CommandReturn>(context, Value(const CommandDone()));
                  try {
                    await Base.signOut();
                  } catch (e, t) {
                    log.warning("Sign out failed", e, t);
                  }
                },
                style: FButtonStyle.primary(),
                child: const Text('Sign In'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

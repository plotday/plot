import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:plot/util/developer_mode.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:collection/collection.dart';
import 'package:plot/notifications/notification_service.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/user.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/api/twist_permission.dart';
import 'package:plot/app_info.dart';
import 'package:plot/env.dart';
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
import 'package:plot/main.dart' show navigatorKey;
import 'package:plot/widget/toast.dart';
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

/// Build the App settings command group from [PrioritiesState].
///
/// Accepts optional [adminOrgs] list (fetched from the API) to include
/// per-org AI preference commands for organizations the user administers.
StaticCommandGroup settingsCommandsFromState(
  PrioritiesState? prioritiesState, {
  bool showAllPriorities = false,
  String? email,
  List<Map<String, dynamic>> adminOrgs = const [],
  SubscriptionInfo? subscription,
}) {
  final hasOrganizations =
      prioritiesState != null &&
      prioritiesState.priorities.any((p) => p.organizationId != null);

  Command? gettingStartedCmd;
  Command? helpFeedbackCmd;
  Command? whatsNewCmd;
  if (prioritiesState != null) {
    final plotPriority = prioritiesState.root?.children.firstWhereOrNull(
      (p) => p.key == '@plot',
    );
    if (plotPriority != null) {
      for (final child in plotPriority.children) {
        final isArchived = child.archivedAt != null;
        if (isArchived && !showAllPriorities) continue;

        if (child.key == '@plot.getting-started') {
          gettingStartedCmd = OpenGettingStarted(child);
        } else if (child.key?.startsWith('@plot.help-feedback') == true) {
          helpFeedbackCmd = OpenHelpFeedback(child);
        } else if (child.key == '@plot.whats-new') {
          whatsNewCmd = OpenWhatsNew(child);
        }
      }
    }
  }

  final rootPriority = prioritiesState?.root;

  return settingsCommands(
    hasOrganizations: hasOrganizations,
    rootPriority: rootPriority,
    gettingStartedCmd: gettingStartedCmd,
    whatsNewCmd: whatsNewCmd,
    helpFeedbackCmd: helpFeedbackCmd,
    email: email,
    adminOrgs: adminOrgs,
    subscription: subscription,
  );
}

StaticCommandGroup settingsCommands({
  bool hasOrganizations = false,
  Priority? rootPriority,
  Command? gettingStartedCmd,
  Command? whatsNewCmd,
  Command? helpFeedbackCmd,
  String? email,
  List<Map<String, dynamic>> adminOrgs = const [],
  SubscriptionInfo? subscription,
}) => StaticCommandGroup(
  title: 'App',
  shortcut: platformSingleActivator(LogicalKeyboardKey.comma),
  commands: [
    if (gettingStartedCmd != null) gettingStartedCmd,
    ManageConnections(),
    ManageTwists(),
    if (subscription != null && !subscription.canBuildTwists) UpgradePlan(),
    if (subscription != null && subscription.hasPaidPlan) ManageSubscription(),
    if (hasOrganizations) ManageOrganizations(),
    CopyPageLink(), OpenCopiedPageLink(),
    ChangeAppearance(),
    ChangeAiPreference(),
    if (NotificationService.isSupported &&
        !NotificationService.instance.isTokenRegistered)
      EnableNotifications(),
    if (rootPriority != null) ShowAttentionSettings(rootPriority),
    for (final org in adminOrgs)
      OrgAiPreferences(
        orgId: org['id'] as String,
        orgName: org['name'] as String,
      ),
    // Only show Enter Behavior setting on devices with physical keyboards
    if (hasPhysicalKeyboard()) ChangeEnterBehavior(),
    if (whatsNewCmd != null) whatsNewCmd,
    if (helpFeedbackCmd != null) helpFeedbackCmd,
    FullResync(),
    CopyVersion(),
    SignOut(email: email),
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
        commandsBuilder: (context) async {
          final prioritiesState = context.read<PrioritiesBloc>().state;
          final userState = context.read<UserBloc>().state;
          final email = userState is UserReady
              ? userState.user.primaryEmail
              : null;

          // Fetch orgs and subscription in parallel
          List<Map<String, dynamic>> adminOrgs = [];
          SubscriptionInfo? subscription;
          try {
            final results = await Future.wait([
              api.get<List<dynamic>>('/organization'),
              UpgradeApi.getSubscription(),
            ]);
            adminOrgs = (results[0] as List<dynamic>)
                .cast<Map<String, dynamic>>()
                .where((o) => o['role'] == 'admin')
                .toList();
            subscription = results[1] as SubscriptionInfo;
          } catch (_) {
            // Non-critical — settings still work without these
          }

          final groups = [
            settingsCommandsFromState(
              prioritiesState,
              email: email,
              adminOrgs: adminOrgs,
              subscription: subscription,
            ),
          ];
          final debugCmds = buildDebugCommands();
          if (debugCmds != null) {
            groups.add(debugCmds);
          }
          return Commands(groups: groups);
        },
        shortcut: platformSingleActivator(LogicalKeyboardKey.comma),
      );
}

class ChangeAppearance extends ShowCommands {
  ChangeAppearance()
    : super(
        title: 'Change light/dark mode',
        icon: FontAwesomeIcons.sun,
        commands: Commands(groups: [appearanceCommands]),
      );
}

class ChangeEnterBehavior extends Command {
  ChangeEnterBehavior()
    : super(
        title: 'Change enter key behavior',
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
          title: 'Enter key behavior',
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
                style: context.theme.typography.md.copyWith(
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
  SignOut({String? email})
    : super(
        title: 'Sign out',
        subtitle: email,
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

class ManageOrganizations extends Command {
  ManageOrganizations()
    : super(
        title: 'Manage organizations',
        description:
            'Manage members, domains, and billing for your organizations.',
        icon: FontAwesomeIcons.building,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final orgs = await api.get<List<dynamic>>('/organization');

      if (orgs.isEmpty) {
        return CommandMessage('You are not a member of any organization');
      }

      if (orgs.length == 1) {
        final url = Uri.parse(
          '${Env.appBaseUrl}/organization/${orgs[0]['id']}',
        );
        await launchUrl(url, mode: LaunchMode.externalApplication);
        return const CommandDone();
      }

      // Multiple orgs — show selection modal
      if (!context.mounted) return const CommandDone();
      final selected = await SelectModal.open<Map<String, dynamic>>(
        context,
        items: (search) async => [
          SelectGroup(
            title: 'Organizations',
            items: orgs.cast<Map<String, dynamic>>(),
          ),
        ],
        itemBuilder: (org, _) => Padding(
          padding: context.theme.spacing.paddingSm,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                org['name'] as String,
                style: context.theme.typography.md.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${org['role']}',
                style: context.theme.typography.sm.copyWith(
                  color: context.theme.plotColors.muted,
                ),
              ),
            ],
          ),
        ),
      );

      if (context.mounted && selected.present) {
        final url = Uri.parse(
          '${Env.appBaseUrl}/organization/${selected.value['id']}',
        );
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to open organization management', e, t);
      return CommandMessage(
        'Failed to open organization management',
        isError: true,
      );
    }
  }
}

class UpgradePlan extends Command {
  UpgradePlan()
    : super(
        title: 'Upgrade your plan',
        icon: FontAwesomeIcons.bolt,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await launchUrl(
      Uri.parse('https://plot.day/upgrade'),
      mode: LaunchMode.externalApplication,
    );
    return const CommandDone();
  }
}

class ManageSubscription extends Command {
  ManageSubscription()
    : super(
        title: 'Manage subscription',
        icon: FontAwesomeIcons.creditCard,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final url = await UpgradeApi.getPortalUrl();
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to open subscription management', e, t);
      return CommandMessage(
        'Failed to open subscription management',
        isError: true,
      );
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
    if (DeveloperMode.recordTap()) {
      return CommandRefresh(
        message: DeveloperMode.isEnabled
            ? 'Developer mode enabled'
            : 'Developer mode disabled',
      );
    }
    try {
      await Clipboard.setData(ClipboardData(text: AppInfo.versionString));
      return CommandRefresh(message: 'Version copied to clipboard');
    } catch (e, t) {
      log.warning("Copy version failed", e, t);
      return CommandMessage('Failed to copy version', isError: true);
    }
  }
}

class ChangeAiPreference extends ShowForm {
  ChangeAiPreference()
    : super(
        title: 'AI preferences',
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
      label: 'Enable AI features',
      details:
          'AI is used for search, smart notifications, and twist capabilities.',
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

    // Fetch existing BYOK keys to pre-populate placeholders
    final existingSuffixes = <String, String>{};
    try {
      final keys = await api.get<List<dynamic>>('/ai-keys');
      for (final k in keys.cast<Map<String, dynamic>>()) {
        existingSuffixes[k['provider'] as String] = k['key_suffix'] as String;
      }
    } catch (_) {}

    return FormData(
      title: 'AI preferences',
      groups: [
        StaticFormGroup(items: [toggle, warning]),
        StaticFormGroup(
          title: 'Your API keys',
          subtitle: 'Your keys are used for AI in your personal priorities.',
          items: _buildByokFields(existingSuffixes),
        ),
        StaticFormGroup(
          items: [
            FormButton(
              key: 'save',
              buildCommand: (values) => _SaveAiPreference(
                aiEnabled: values['aiEnabled'] as bool,
                previousValue: currentValue,
                openaiKey: values['openai'] as String?,
                anthropicKey: values['anthropic'] as String?,
                googleKey: values['google'] as String?,
                orgId: null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class EnableNotifications extends Command {
  EnableNotifications()
    : super(
        title: 'Enable notifications',
        subtitle: NotificationService.instance.isPermissionDenied
            ? 'Permission denied — tap to fix'
            : 'Not yet registered',
        icon: FontAwesomeIcons.bell,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final result = await NotificationService.instance.requestPermission();

    return switch (result) {
      NotificationPermissionResult.granted => CommandMessage(
        'Notifications enabled',
      ),
      NotificationPermissionResult.denied => CommandMessage(
        'Permission denied. You can enable notifications in your device settings.',
        isError: true,
      ),
      NotificationPermissionResult.deniedPermanently => _openSystemSettings(),
      NotificationPermissionResult.unsupported => CommandMessage(
        'Notifications are not supported on this platform',
        isError: true,
      ),
      NotificationPermissionResult.error => CommandMessage(
        'Failed to enable notifications',
        isError: true,
      ),
    };
  }

  CommandReturn _openSystemSettings() {
    if (Platform.isMacOS) {
      // Open macOS System Settings → Notifications for this app
      launchUrl(Uri.parse('x-apple.systempreferences:com.apple.Notifications-Settings'));
    }
    return CommandMessage(
      'Please enable notifications in your device settings, then return to Plot.',
    );
  }
}

/// Build text fields for each AI provider key.
/// Shows existing key suffix as placeholder when a key is already configured.
List<FormItem> _buildByokFields(Map<String, String> existingSuffixes) {
  return [
    for (final provider in ['openai', 'anthropic', 'google'])
      FormTextInput(
        key: provider,
        label: _providerDisplayName(provider),
        placeholder: existingSuffixes.containsKey(provider)
            ? 'Configured (...${existingSuffixes[provider]})'
            : 'Paste API key',
      ),
  ];
}

String _providerDisplayName(String provider) {
  return switch (provider) {
    'openai' => 'OpenAI',
    'anthropic' => 'Anthropic',
    'google' => 'Google',
    _ => provider,
  };
}

/// Command for per-org AI preferences (BYOK keys only, no AI toggle).
class OrgAiPreferences extends ShowForm {
  OrgAiPreferences({required this.orgId, required this.orgName})
    : super(
        title: '$orgName AI preferences',
        icon: FontAwesomeIcons.robot,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
        form: (context) => _buildOrgForm(context, orgId, orgName),
      );

  final String orgId;
  final String orgName;

  static Future<FormData> _buildOrgForm(
    BuildContext context,
    String orgId,
    String orgName,
  ) async {
    final existingSuffixes = <String, String>{};
    try {
      final keys = await api.get<List<dynamic>>('/organization/$orgId/ai-keys');
      for (final k in keys.cast<Map<String, dynamic>>()) {
        existingSuffixes[k['provider'] as String] = k['key_suffix'] as String;
      }
    } catch (_) {}

    return FormData(
      title: '$orgName AI preferences',
      groups: [
        StaticFormGroup(
          title: 'Organization API keys',
          subtitle: 'These keys are used for AI in $orgName priorities.',
          items: _buildByokFields(existingSuffixes),
        ),
        StaticFormGroup(
          items: [
            FormButton(
              key: 'save',
              buildCommand: (values) => _SaveAiPreference(
                aiEnabled: null,
                previousValue: null,
                openaiKey: values['openai'] as String?,
                anthropicKey: values['anthropic'] as String?,
                googleKey: values['google'] as String?,
                orgId: orgId,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SaveAiPreference extends Command {
  _SaveAiPreference({
    required this.aiEnabled,
    required this.previousValue,
    this.openaiKey,
    this.anthropicKey,
    this.googleKey,
    this.orgId,
  }) : super(
         title: 'Save',
         eventObject: EventObject.settings,
         eventAction: EventAction.updated,
       );

  /// null when saving org-only preferences (no AI toggle).
  final bool? aiEnabled;
  final bool? previousValue;
  final String? openaiKey;
  final String? anthropicKey;
  final String? googleKey;

  /// non-null when saving org keys.
  final String? orgId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      // Save BYOK keys (validate each non-empty key first)
      final keysToSave = <String, String>{};
      if (openaiKey != null && openaiKey!.trim().isNotEmpty) {
        keysToSave['openai'] = openaiKey!.trim();
      }
      if (anthropicKey != null && anthropicKey!.trim().isNotEmpty) {
        keysToSave['anthropic'] = anthropicKey!.trim();
      }
      if (googleKey != null && googleKey!.trim().isNotEmpty) {
        keysToSave['google'] = googleKey!.trim();
      }

      final basePath = orgId != null
          ? '/organization/$orgId/ai-keys'
          : '/ai-keys';

      for (final entry in keysToSave.entries) {
        final result = await api.post<Map<String, dynamic>>(
          basePath,
          body: {'provider': entry.key, 'key': entry.value},
        );

        // The API returns 400 with { error: ... } if validation fails.
        // api.post throws on non-2xx, so we get here only on success.
        // Check for warnings (key saved but validation uncertain).
        final warning = result['warning'] as String?;
        if (warning != null) {
          return CommandMessage(
            '${_providerDisplayName(entry.key)}: $warning',
            isError: true,
          );
        }
      }

      // Save AI toggle (personal preferences only)
      if (aiEnabled != null && context.mounted) {
        await context.read<SettingsBloc>().setAiEnabled(aiEnabled!);

        // If toggling AI off, archive twists that require AI
        if (previousValue == true && !aiEnabled!) {
          final archived = await _archiveAiRequiringTwists();
          if (archived > 0) {
            return CommandMessage(
              'AI disabled. $archived twist${archived == 1 ? '' : 's'} archived.',
            );
          }
        }
      }

      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to save AI preferences', e, t);
      // Extract error message from API response if available
      final msg = e.toString();
      if (msg.contains('Invalid API key')) {
        return CommandMessage('Invalid API key', isError: true);
      }
      return CommandMessage('Failed to save: $msg', isError: true);
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
        final aiTwists = twists.where(
          (t) =>
              t.permissions?.hasPermission(
                'ai',
                'prompt',
                PermissionFlag.use,
              ) ==
              true,
        );

        // Get active local priority_twists for this priority to find IDs
        final localTwists = await PriorityTwist.get(
          priorityId: priority.id,
          includeAncestors: false,
          archived: false,
        );

        for (final aiTwist in aiTwists) {
          // Find matching local priority_twist
          final localTwist = localTwists
              .where((lt) => lt.twistId.toString() == aiTwist.id)
              .firstOrNull;

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

class FullResync extends Command {
  FullResync()
    : super(
        title: 'Full re-sync',
        icon: PlotIcon.sync,
        eventObject: EventObject.sync,
        eventAction: EventAction.started,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    Store.get.fullResync().catchError((Object e, StackTrace t) {
      log.warning('Full re-sync failed', e, t);
      Tracker.trackError(
        eventObject.value,
        errorType: e.runtimeType.toString(),
        errorMessage: e.toString(),
        stackTrace: extractStackTrace(t),
        context: 'full_resync',
      );
      final ctx = navigatorKey?.currentContext;
      if (ctx != null && ctx.mounted) {
        ctx.showToast(message: 'Full re-sync failed', isError: true);
      }
    });

    return CommandMessage('Re-sync started');
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
            style: context.theme.typography.md.copyWith(
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
                variant: FButtonVariant.secondary,
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
                variant: FButtonVariant.primary,
                child: const Text('Sign In'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

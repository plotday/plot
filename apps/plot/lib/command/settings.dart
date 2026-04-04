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
import 'package:plot/api/api_exception.dart';
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
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/main.dart' show navigatorKey;
import 'package:plot/widget/otp_input.dart';
import 'package:plot/widget/spinner.dart';
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
List<StaticCommandGroup> settingsCommandsFromState(
  PrioritiesState? prioritiesState, {
  bool showAllPriorities = false,
  String? email,
  List<Map<String, dynamic>> adminOrgs = const [],
  SubscriptionInfo? subscription,
}) {
  final hasOrganizations =
      prioritiesState != null &&
      prioritiesState.priorities.any((p) => p.organizationId != null);

  Command? plotAppCmd;
  if (prioritiesState != null) {
    final plotApp = prioritiesState.priorities.firstWhereOrNull(
      (p) => p.key == '@plot.app',
    );
    if (plotApp != null) {
      final isArchived = plotApp.archivedAt != null;
      if (!isArchived || showAllPriorities) {
        plotAppCmd = OpenPlotApp(plotApp);
      }
    }
  }

  final rootPriority = prioritiesState?.root;

  return settingsCommands(
    hasOrganizations: hasOrganizations,
    rootPriority: rootPriority,
    plotAppCmd: plotAppCmd,
    email: email,
    adminOrgs: adminOrgs,
    subscription: subscription,
  );
}

List<StaticCommandGroup> settingsCommands({
  bool hasOrganizations = false,
  Priority? rootPriority,
  Command? plotAppCmd,
  String? email,
  List<Map<String, dynamic>> adminOrgs = const [],
  SubscriptionInfo? subscription,
}) => [
  StaticCommandGroup(
    title: 'Settings',
    shortcut: platformSingleActivator(LogicalKeyboardKey.comma),
    commands: [
      ManageConnections(),
      ManageTwists(),
      ManageLinkedEmails(),
      ChangeAppearance(),
      if (NotificationService.isSupported &&
          !NotificationService.instance.isTokenRegistered)
        EnableNotifications(),
      if (rootPriority != null) ShowAttentionSettings(rootPriority),
      ChangeAiPreference(),
      for (final org in adminOrgs)
        if (org['plan'] != 'free')
          OrgAiPreferences(
            orgId: org['id'] as String,
            orgName: org['name'] as String,
          ),
      // Only show Enter Behavior setting on devices with physical keyboards
      if (hasPhysicalKeyboard()) ChangeEnterBehavior(),
      if (subscription != null && subscription.hasPaidPlan)
        ManageSubscription(),
      if (hasOrganizations) ManageOrganizations(),
    ],
  ),
  StaticCommandGroup(
    title: 'App',
    commands: [
      if (plotAppCmd != null) plotAppCmd,
      if (subscription != null && !subscription.canBuildTwists) UpgradePlan(),
      CopyPageLink(),
      OpenCopiedPageLink(),
      FullResync(),
      CopyVersion(),
      SignOut(email: email),
    ],
  ),
];

final signedOutSettingsCommands = [
  StaticCommandGroup(title: 'Settings', commands: [ChangeAppearance()]),
  StaticCommandGroup(title: 'App', commands: [CopyVersion()]),
];

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
            final allOrgs = (results[0] as List<dynamic>)
                .cast<Map<String, dynamic>>();
            log.info(
              'ShowSettings: /organization returned ${allOrgs.length} orgs: $allOrgs',
            );
            adminOrgs = allOrgs.where((o) => o['role'] == 'admin').toList();
            log.info('ShowSettings: adminOrgs after role filter: $adminOrgs');
            subscription = results[1] as SubscriptionInfo;
          } catch (e, t) {
            // Non-critical — settings still work without these
            log.warning('Failed to fetch orgs/subscription for settings', e, t);
          }

          final groups = [
            ...settingsCommandsFromState(
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
        title: 'Light/dark mode',
        icon: FontAwesomeIcons.sun,
        commands: Commands(groups: [appearanceCommands]),
      );
}

class ChangeEnterBehavior extends Command {
  ChangeEnterBehavior()
    : super(
        title: 'Enter key behavior',
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
        title: 'Organizations',
        description: 'Members, domains, and billing for your organizations.',
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
        final url = Uri.parse('${Env.siteRoot}/organization/${orgs[0]['id']}');
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
          '${Env.siteRoot}/organization/${selected.value['id']}',
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
      Uri.parse('${Env.siteRoot}/upgrade'),
      mode: LaunchMode.externalApplication,
    );
    return const CommandDone();
  }
}

class ManageSubscription extends Command {
  ManageSubscription()
    : super(
        title: 'Subscription',
        icon: FontAwesomeIcons.creditCard,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await launchUrl(
      Uri.parse('${Env.siteRoot}/upgrade'),
      mode: LaunchMode.externalApplication,
    );
    return const CommandDone();
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
    final groups = await _buildGroups(null);

    return FormData(
      title: 'AI preferences',
      groups: groups,
      onRefresh: () => _buildResolvedGroups(null),
    );
  }

  static Future<List<FormGroup>> _buildGroups(String? orgId) async {
    // Fetch existing providers and preferences
    final providers = await _fetchProviders(orgId);
    final prefs = await _fetchPreference(orgId);

    // Provider list items
    final providerItems = _buildProviderListItems(providers, orgId);

    // Built-in features provider select
    final builtinSelect = _buildProviderSelect(
      key: 'builtinAiKeyId',
      label: 'AI provider for built-in features',
      providers: providers,
      initialValue: prefs['builtin_ai_disabled'] == true
          ? 'disabled'
          : prefs['builtin_ai_key_id'],
      includeDisabled: true,
    );

    // Twist AI provider select
    final twistSelect = _buildProviderSelect(
      key: 'twistAiKeyId',
      label: 'AI provider for twists',
      providers: providers,
      initialValue: prefs['twist_ai_disabled'] == true
          ? 'disabled'
          : prefs['twist_ai_key_id'],
      includeDisabled: true,
    );

    return [
      StaticFormGroup(items: [builtinSelect, twistSelect]),
      StaticFormGroup(
        title: 'AI providers',
        items: [
          ...providerItems,
          FormButton(
            key: 'addProvider',
            isPrimary: false,
            buildCommand: (_) => _AddAiProvider(orgId: orgId),
          ),
        ],
      ),
      StaticFormGroup(
        items: [
          FormButton(
            key: 'save',
            isPrimary: true,
            buildCommand: (values) => _SaveAiPreference(
              builtinAiKeyId: values['builtinAiKeyId'],
              twistAiKeyId: values['twistAiKeyId'],
              orgId: orgId,
            ),
          ),
        ],
      ),
    ];
  }

  static Future<List<StaticFormGroup>> _buildResolvedGroups(
    String? orgId,
  ) async {
    final groups = await _buildGroups(orgId);
    final resolved = <StaticFormGroup>[];
    for (final group in groups) {
      final items = await group.list();
      if (items.isNotEmpty) {
        resolved.add(StaticFormGroup(
          title: group.title,
          subtitle: group.subtitle,
          items: items,
        ));
      }
    }
    return resolved;
  }
}

class EnableNotifications extends Command {
  EnableNotifications()
    : super(
        title: 'Notifications',
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
      launchUrl(
        Uri.parse('x-apple.systempreferences:com.apple.Notifications-Settings'),
      );
    }
    return CommandMessage(
      'Please enable notifications in your device settings, then return to Plot.',
    );
  }
}

String _providerDisplayName(String provider) {
  return switch (provider) {
    'openai' => 'OpenAI',
    'anthropic' => 'Anthropic',
    'google' => 'Google',
    'custom' => 'Custom',
    _ => provider,
  };
}

/// Fetch configured AI providers for a user or org.
Future<List<Map<String, dynamic>>> _fetchProviders(String? orgId) async {
  try {
    final path = orgId != null ? '/organization/$orgId/ai-keys' : '/ai-keys';
    final keys = await api.get<List<dynamic>>(path);
    return keys.cast<Map<String, dynamic>>();
  } catch (_) {
    return [];
  }
}

/// Fetch AI preference selections for a user or org.
Future<Map<String, dynamic>> _fetchPreference(String? orgId) async {
  try {
    final path = orgId != null
        ? '/organization/$orgId/ai-preference'
        : '/ai-preference';
    return await api.get<Map<String, dynamic>>(path);
  } catch (_) {
    return {
      'builtin_ai_key_id': null,
      'twist_ai_key_id': null,
      'twist_ai_disabled': false,
    };
  }
}

/// Build FormInfo items showing configured providers with remove buttons.
List<FormItem> _buildProviderListItems(
  List<Map<String, dynamic>> providers,
  String? orgId,
) {
  return [
    for (final p in providers)
      FormInfo(
        key: 'provider_${p['id']}',
        builder: (context) {
          final provider = p['provider'] as String;
          final suffix = p['key_suffix'] as String;
          final name = p['name'] as String?;
          final label = provider == 'custom'
              ? (name ?? 'Custom')
              : _providerDisplayName(provider);
          return Padding(
            padding: EdgeInsets.only(
              left: context.theme.spacing.xl,
              right: context.theme.spacing.xl,
              bottom: context.theme.spacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$label (...$suffix)',
                    style: context.theme.typography.md,
                  ),
                ),
                GestureDetector(
                  onTap: () async {
                    final basePath = orgId != null
                        ? '/organization/$orgId/ai-keys/${p['id']}'
                        : '/ai-keys/${p['id']}';
                    try {
                      await api.delete<Map<String, dynamic>>(basePath);
                      if (context.mounted) {
                        context.showToast(message: 'Provider removed');
                        await FormScope.of(context)?.refresh?.call();
                      }
                    } catch (e) {
                      if (context.mounted) {
                        context.showToast(
                          message: 'Failed to remove',
                          isError: true,
                        );
                      }
                    }
                  },
                  child: Icon(
                    FontAwesomeIcons.xmark,
                    size: 14,
                    color: context.theme.colors.mutedForeground,
                  ),
                ),
              ],
            ),
          );
        },
      ),
  ];
}

/// Build a provider selection dropdown.
FormSelect<dynamic> _buildProviderSelect({
  required String key,
  required String label,
  required List<Map<String, dynamic>> providers,
  required dynamic initialValue,
  required bool includeDisabled,
}) {
  return FormSelect<dynamic>(
    key: key,
    label: label,
    initialValue: initialValue,
    hasInitialValue: true,
    titleBuilder: (value) {
      if (value == null) return 'Plot';
      if (value == 'disabled') return 'Disabled';
      // Find the provider by id
      final p = providers.firstWhereOrNull(
        (p) => p['id'] == value || p['id'].toString() == value.toString(),
      );
      if (p == null) return 'Plot';
      final provider = p['provider'] as String;
      final name = p['name'] as String?;
      return provider == 'custom'
          ? (name ?? 'Custom')
          : _providerDisplayName(provider);
    },
    items: (_) async => [
      null, // Plot
      ...providers.map((p) => p['id']),
      if (includeDisabled) 'disabled',
    ],
  );
}

/// Command for per-org AI preferences.
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
    final groups = await _buildOrgGroups(orgId, orgName);

    return FormData(
      title: '$orgName AI preferences',
      groups: groups,
      onRefresh: () => _buildResolvedOrgGroups(orgId, orgName),
    );
  }

  static Future<List<FormGroup>> _buildOrgGroups(
    String orgId,
    String orgName,
  ) async {
    final providers = await _fetchProviders(orgId);
    final prefs = await _fetchPreference(orgId);

    final providerItems = _buildProviderListItems(providers, orgId);

    final builtinSelect = _buildProviderSelect(
      key: 'builtinAiKeyId',
      label: 'Built-in features',
      providers: providers,
      initialValue: prefs['builtin_ai_disabled'] == true
          ? 'disabled'
          : prefs['builtin_ai_key_id'],
      includeDisabled: true,
    );

    final twistSelect = _buildProviderSelect(
      key: 'twistAiKeyId',
      label: 'Twists using AI',
      providers: providers,
      initialValue: prefs['twist_ai_disabled'] == true
          ? 'disabled'
          : prefs['twist_ai_key_id'],
      includeDisabled: true,
    );

    return [
      StaticFormGroup(
        title: 'AI providers',
        subtitle: 'These providers are used for AI in $orgName priorities.',
        items: [
          builtinSelect,
          twistSelect,
          ...providerItems,
          FormButton(
            key: 'addProvider',
            isPrimary: false,
            buildCommand: (_) => _AddAiProvider(orgId: orgId),
          ),
        ],
      ),
      StaticFormGroup(
        items: [
          FormButton(
            key: 'save',
            isPrimary: true,
            buildCommand: (values) => _SaveAiPreference(
              builtinAiKeyId: values['builtinAiKeyId'],
              twistAiKeyId: values['twistAiKeyId'],
              orgId: orgId,
            ),
          ),
        ],
      ),
    ];
  }

  static Future<List<StaticFormGroup>> _buildResolvedOrgGroups(
    String orgId,
    String orgName,
  ) async {
    final groups = await _buildOrgGroups(orgId, orgName);
    final resolved = <StaticFormGroup>[];
    for (final group in groups) {
      final items = await group.list();
      if (items.isNotEmpty) {
        resolved.add(StaticFormGroup(
          title: group.title,
          subtitle: group.subtitle,
          items: items,
        ));
      }
    }
    return resolved;
  }
}

/// Opens a provider selection list, then shows the configuration form.
class _AddAiProvider extends Command {
  _AddAiProvider({this.orgId})
    : super(
        title: 'Add provider',
        icon: FontAwesomeIcons.plus,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
      );

  final String? orgId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final existing = await _fetchProviders(orgId);
    final configuredStandard = existing
        .where((p) => p['provider'] != 'custom')
        .map((p) => p['provider'] as String)
        .toSet();

    final availableProviders = <String>[
      if (!configuredStandard.contains('openai')) 'openai',
      if (!configuredStandard.contains('anthropic')) 'anthropic',
      if (!configuredStandard.contains('google')) 'google',
      'custom',
    ];

    if (!context.mounted) return const CommandSkipped();

    final result = await SelectModal.open<String>(
      context,
      showFilter: false,
      items: (_) async => [SelectGroup(items: availableProviders)],
      itemBuilder: (provider, _) => Padding(
        padding: context.theme.spacing.paddingSm,
        child: Text(
          provider == 'custom' ? 'Custom' : _providerDisplayName(provider),
          style: context.theme.typography.md.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );

    if (!context.mounted || !result.present) return const CommandDone();

    final configResult = await _ConfigureAiProvider(
      provider: result.value,
      orgId: orgId,
    ).run(context);

    // Don't propagate CommandDone — it would pop the parent AI preferences form.
    // Return CommandSkipped so the user stays in AI preferences.
    if (configResult is CommandDone) {
      if (context.mounted) {
        context.showToast(message: 'Provider added');
      }
      return const CommandSkipped();
    }
    return configResult;
  }
}

/// Configuration form for a specific AI provider.
class _ConfigureAiProvider extends ShowForm {
  _ConfigureAiProvider({required this.provider, this.orgId})
    : super(
        title: provider == 'custom'
            ? 'Add custom provider'
            : 'Add ${_providerDisplayName(provider)}',
        icon: FontAwesomeIcons.plus,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
        form: (context) => _buildForm(provider, orgId),
      );

  final String provider;
  final String? orgId;

  static Future<FormData> _buildForm(String provider, String? orgId) async {
    final isCustom = provider == 'custom';
    final title = isCustom
        ? 'Add custom provider'
        : 'Add ${_providerDisplayName(provider)}';

    return FormData(
      title: title,
      groups: [
        StaticFormGroup(
          items: [
            if (isCustom)
              FormTextInput(
                key: 'name',
                label: 'Display name',
                required: true,
                placeholder: 'e.g. Local Ollama',
              ),
            if (isCustom)
              FormTextInput(
                key: 'customBaseUrl',
                label: 'Base URL',
                required: true,
                placeholder: 'e.g. http://localhost:11434/v1',
              ),
            FormTextInput(
              key: 'apiKey',
              label: 'API key',
              required: true,
              placeholder: 'Paste API key',
            ),
            if (isCustom)
              FormTextInput(
                key: 'fastModel',
                label: 'Fast model',
                required: true,
                placeholder: 'e.g. llama3.2',
              ),
            if (isCustom)
              FormTextInput(
                key: 'thinkingModel',
                label: 'Thinking model',
                required: true,
                placeholder: 'e.g. qwq',
              ),
          ],
        ),
        StaticFormGroup(
          items: [
            FormButton(
              key: 'save',
              buildCommand: (values) => _SaveAiProvider(
                provider: provider,
                apiKey: values['apiKey'] as String?,
                name: values['name'] as String?,
                customBaseUrl: values['customBaseUrl'] as String?,
                fastModel: values['fastModel'] as String?,
                thinkingModel: values['thinkingModel'] as String?,
                orgId: orgId,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Saves a new AI provider key.
class _SaveAiProvider extends Command {
  _SaveAiProvider({
    required this.provider,
    required this.apiKey,
    this.name,
    this.customBaseUrl,
    this.fastModel,
    this.thinkingModel,
    this.orgId,
  }) : super(
         title: 'Save',
         eventObject: EventObject.settings,
         eventAction: EventAction.updated,
       );

  final String? provider;
  final String? apiKey;
  final String? name;
  final String? customBaseUrl;
  final String? fastModel;
  final String? thinkingModel;
  final String? orgId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (provider == null || provider!.isEmpty) {
      return CommandMessage('Please select a provider', isError: true);
    }
    if (apiKey == null || apiKey!.trim().isEmpty) {
      return CommandMessage('API key is required', isError: true);
    }
    if (provider == 'custom') {
      if (name == null || name!.trim().isEmpty) {
        return CommandMessage('Display name is required', isError: true);
      }
      if (customBaseUrl == null || customBaseUrl!.trim().isEmpty) {
        return CommandMessage('Base URL is required', isError: true);
      }
      if (fastModel == null || fastModel!.trim().isEmpty) {
        return CommandMessage('Fast model is required', isError: true);
      }
      if (thinkingModel == null || thinkingModel!.trim().isEmpty) {
        return CommandMessage('Thinking model is required', isError: true);
      }
    }

    try {
      final basePath = orgId != null
          ? '/organization/$orgId/ai-keys'
          : '/ai-keys';

      final body = <String, dynamic>{
        'provider': provider,
        'key': apiKey!.trim(),
      };
      if (provider == 'custom') {
        body['name'] = name!.trim();
        body['customBaseUrl'] = customBaseUrl!.trim();
        body['fastModel'] = fastModel!.trim();
        body['thinkingModel'] = thinkingModel!.trim();
      }

      final result = await api.post<Map<String, dynamic>>(basePath, body: body);

      final warning = result['warning'] as String?;
      if (warning != null) {
        return CommandMessage(warning, isError: true);
      }

      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to save AI provider', e, t);
      final msg = e.toString();
      if (msg.contains('Invalid API key')) {
        return CommandMessage('Invalid API key', isError: true);
      }
      return CommandMessage('Failed to save: $msg', isError: true);
    }
  }
}

class _SaveAiPreference extends Command {
  _SaveAiPreference({this.builtinAiKeyId, this.twistAiKeyId, this.orgId})
    : super(
        title: 'Save',
        icon: FontAwesomeIcons.check,
        eventObject: EventObject.settings,
        eventAction: EventAction.updated,
      );

  final dynamic builtinAiKeyId;
  final dynamic twistAiKeyId;

  /// non-null when saving org keys.
  final String? orgId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      // Save provider selections
      final prefPath = orgId != null
          ? '/organization/$orgId/ai-preference'
          : '/ai-preference';

      final prefBody = <String, dynamic>{};

      // builtinAiKeyId: 'disabled' means disabled, null means Plot, int means provider
      if (builtinAiKeyId == 'disabled') {
        prefBody['builtinAiKeyId'] = null;
        prefBody['builtinAiDisabled'] = true;
      } else if (builtinAiKeyId == null) {
        prefBody['builtinAiKeyId'] = null;
        prefBody['builtinAiDisabled'] = false;
      } else {
        prefBody['builtinAiKeyId'] = builtinAiKeyId is int
            ? builtinAiKeyId
            : int.tryParse(builtinAiKeyId.toString());
        prefBody['builtinAiDisabled'] = false;
      }

      // twistAiKeyId: 'disabled' means disabled, null means Plot, int means provider
      if (twistAiKeyId == 'disabled') {
        prefBody['twistAiKeyId'] = null;
        prefBody['twistAiDisabled'] = true;
      } else if (twistAiKeyId == null) {
        prefBody['twistAiKeyId'] = null;
        prefBody['twistAiDisabled'] = false;
      } else {
        prefBody['twistAiKeyId'] = twistAiKeyId is int
            ? twistAiKeyId
            : int.tryParse(twistAiKeyId.toString());
        prefBody['twistAiDisabled'] = false;
      }

      await api.post<Map<String, dynamic>>(prefPath, body: prefBody);

      // Update local AI enabled state (personal preferences only)
      if (orgId == null && context.mounted) {
        final builtinDisabled = builtinAiKeyId == 'disabled';
        final twistDisabled = twistAiKeyId == 'disabled';
        await context.read<SettingsBloc>().setAiEnabled(
          !(builtinDisabled && twistDisabled),
        );

        // If twist AI was just disabled, archive twists that require AI
        if (twistDisabled) {
          final archived = await _archiveAiRequiringTwists();
          if (archived > 0) {
            return CommandMessage(
              'Twist AI disabled. $archived twist${archived == 1 ? '' : 's'} archived.',
            );
          }
        }
      }

      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to save AI preferences', e, t);
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
        title: 'Re-sync all data',
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

/// Top-level command: lists linked emails and offers add/remove/make-primary.
class ManageLinkedEmails extends ShowCommands {
  ManageLinkedEmails()
    : super(
        title: 'Linked emails',
        icon: FontAwesomeIcons.envelope,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
        commandsBuilder: _buildCommands,
      );

  static Future<Commands> _buildCommands(BuildContext context) async {
    List<Map<String, dynamic>> emails = [];
    try {
      final result = await api.get<Map<String, dynamic>>('/link-email');
      emails = (result['emails'] as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (e, t) {
      log.warning('Failed to fetch linked emails', e, t);
    }

    final primaryEmail = emails
        .where((e) => e['primary'] as bool)
        .map((e) => e['email'] as String)
        .firstOrNull;

    final otherEmails = emails.where((e) => !(e['primary'] as bool)).toList();

    return Commands(
      groups: [
        StaticCommandGroup(
          title: 'Linked emails',
          infoBuilder: primaryEmail != null
              ? (context, _) {
                  final iconSize = context.theme.iconSizes.base;
                  return Padding(
                    // Match ListTile layout: 20px left, vertical from paddingSm
                    padding: EdgeInsets.only(
                      left: 20,
                      right: 20,
                      top: context.theme.spacing.sm,
                      bottom: context.theme.spacing.sm,
                    ),
                    child: Row(
                      spacing: 12,
                      children: [
                        SizedBox(
                          height: iconSize,
                          child: Center(
                            child: Icon(
                              FontAwesomeIcons.solidEnvelope,
                              size: iconSize,
                              color: context.theme.plotColors.muted,
                            ),
                          ),
                        ),
                        Text(primaryEmail, style: context.theme.typography.md),
                        Text(
                          'Primary',
                          style: context.theme.typography.md.copyWith(
                            color: context.theme.plotColors.muted,
                          ),
                        ),
                      ],
                    ),
                  );
                }
              : null,
          commands: [
            for (final email in otherEmails)
              _EmailActions(
                contactId: email['id'] as String,
                email: email['email'] as String,
                totalCount: emails.length,
              ),
            _AddEmail(),
          ],
        ),
      ],
    );
  }
}

/// Sub-menu for a non-primary linked email: make primary / remove.
class _EmailActions extends ShowCommands {
  _EmailActions({
    required this.contactId,
    required this.email,
    required this.totalCount,
  }) : super(
         title: email,
         icon: FontAwesomeIcons.envelope,
         commands: Commands(
           groups: [
             StaticCommandGroup(
               title: email,
               commands: [
                 _MakePrimary(contactId: contactId, email: email),
                 if (totalCount > 1)
                   _RemoveEmail(contactId: contactId, email: email),
               ],
             ),
           ],
         ),
       );

  final String contactId;
  final String email;
  final int totalCount;
}

class _MakePrimary extends Command {
  _MakePrimary({required this.contactId, required this.email})
    : super(
        title: 'Make primary',
        icon: FontAwesomeIcons.star,
        eventObject: EventObject.settings,
        eventAction: EventAction.updated,
      );

  final String contactId;
  final String email;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/link-email/primary',
        body: {'contactId': contactId},
      );
      return CommandMessage('$email is now your primary email');
    } on ApiException catch (e) {
      return CommandMessage(e.description, isError: true);
    } catch (e, t) {
      log.warning('Failed to make email primary', e, t);
      Tracker.captureException(e, t);
      return CommandMessage('Failed to update primary email', isError: true);
    }
  }
}

class _RemoveEmail extends Command {
  _RemoveEmail({required this.contactId, required this.email})
    : super(
        title: 'Remove email',
        icon: FontAwesomeIcons.trash,
        eventObject: EventObject.settings,
        eventAction: EventAction.deleted,
      );

  final String contactId;
  final String email;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.delete<Map<String, dynamic>>('/link-email/$contactId');
      return CommandMessage('$email has been removed');
    } on ApiException catch (e) {
      return CommandMessage(e.description, isError: true);
    } catch (e, t) {
      log.warning('Failed to remove email', e, t);
      Tracker.captureException(e, t);
      return CommandMessage('Failed to remove email', isError: true);
    }
  }
}

/// Add a new email address via OTP verification.
class _AddEmail extends ShowPage {
  _AddEmail()
    : super(
        title: 'Add email address',
        icon: FontAwesomeIcons.plus,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
        builder: (context) => _AddEmailContent(),
      );
}

enum _AddEmailMode { enterEmail, otpSent, success }

class _AddEmailContent extends StatefulWidget {
  @override
  State<_AddEmailContent> createState() => _AddEmailContentState();
}

class _AddEmailContentState extends State<_AddEmailContent> {
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  _AddEmailMode _mode = _AddEmailMode.enterEmail;
  bool _isLoading = false;
  int _otpResetCounter = 0;

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _handleSendCode() async {
    final email = _emailController.text.trim().toLowerCase();
    if (email.isEmpty) {
      context.showToast(
        message: 'Please enter an email address',
        isError: true,
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final result = await api.post<Map<String, dynamic>>(
        '/link-email/send',
        body: {'email': email},
      );

      if (!mounted) return;

      if (result['message'] == 'already_linked') {
        context.showToast(
          message: 'This email is already linked to your account',
        );
        Modal.pop<CommandReturn>(context, Value(const CommandDone()));
        return;
      }

      setState(() {
        _mode = _AddEmailMode.otpSent;
        _isLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      context.showToast(message: e.description, isError: true);
      setState(() => _isLoading = false);
    } catch (e, t) {
      log.warning('Failed to send link-email code', e, t);
      Tracker.captureException(e, t);
      if (!mounted) return;
      context.showToast(
        message: 'Something went wrong. Please try again.',
        isError: true,
      );
      setState(() => _isLoading = false);
    }
  }

  Future<void> _handleVerifyCode() async {
    if (_isLoading) return;

    final email = _emailController.text.trim().toLowerCase();
    final code = _otpController.text.trim();

    if (code.isEmpty) {
      context.showToast(
        message: 'Please enter the verification code',
        isError: true,
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await api.post<Map<String, dynamic>>(
        '/link-email/verify',
        body: {'email': email, 'code': code},
      );

      if (!mounted) return;
      setState(() {
        _mode = _AddEmailMode.success;
        _isLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      context.showToast(message: e.description, isError: true);
      setState(() => _isLoading = false);
    } catch (e, t) {
      log.warning('Failed to verify link-email code', e, t);
      Tracker.captureException(e, t);
      if (!mounted) return;
      context.showToast(
        message: 'Something went wrong. Please try again.',
        isError: true,
      );
      setState(() => _isLoading = false);
    }
  }

  Future<void> _handleResendCode() async {
    setState(() {
      _otpResetCounter++;
      _otpController.clear();
    });
    await _handleSendCode();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: context.theme.spacing.padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Add email address',
            style: context.theme.typography.lg.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),

          if (_mode == _AddEmailMode.success) ...[
            Text(
              'Email linked successfully! You can now sign in with this email address.',
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
                  variant: FButtonVariant.primary,
                  child: const Text('Done'),
                ),
              ],
            ),
          ] else if (_mode == _AddEmailMode.otpSent) ...[
            FAlert(
              title: const Text(
                'Check your email!\nWe sent a verification code to',
              ),
              subtitle: Text(
                _emailController.text.trim(),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 16),
            Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: _isLoading ? 0.3 : 1.0,
                  child: Column(
                    spacing: 8,
                    children: [
                      Text(
                        'Enter the 6-digit code from your email:',
                        style: context.theme.typography.md,
                        textAlign: TextAlign.center,
                      ),
                      OtpInput(
                        key: ValueKey(_otpResetCounter),
                        controller: _otpController,
                        onComplete: _handleVerifyCode,
                      ),
                    ],
                  ),
                ),
                if (_isLoading) const Spinner.message('Verifying...'),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FButton(
                  onPress: _isLoading ? null : _handleResendCode,
                  variant: FButtonVariant.ghost,
                  child: const Text('Resend code'),
                ),
                const SizedBox(width: 8),
                const Text('·'),
                const SizedBox(width: 8),
                FButton(
                  onPress: () {
                    setState(() {
                      _mode = _AddEmailMode.enterEmail;
                      _otpController.clear();
                    });
                  },
                  variant: FButtonVariant.ghost,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ] else ...[
            Text(
              'Link an additional email address to your account. '
              'You will be able to sign in with it.',
              style: context.theme.typography.md.copyWith(
                color: context.theme.colors.mutedForeground,
              ),
            ),
            const SizedBox(height: 16),
            FTextField(
              control: .managed(controller: _emailController),
              hint: 'your@email.com',
              label: const Text('Email'),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              autofocus: true,
              autocorrect: false,
              onSubmit: (_) => _handleSendCode(),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FButton(
                  onPress: () => Modal.pop<CommandReturn>(
                    context,
                    Value(const CommandDone()),
                  ),
                  variant: FButtonVariant.secondary,
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 120,
                  child: FButton(
                    onPress: _isLoading ? null : _handleSendCode,
                    variant: FButtonVariant.primary,
                    child: _isLoading
                        ? const Spinner()
                        : const Text('Send code'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
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

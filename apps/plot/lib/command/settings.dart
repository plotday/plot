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
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/user.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/account_api.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/api/twist_permission.dart';
import 'package:plot/app_info.dart';
import 'package:plot/env.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/widget/priorities_shell.dart' show PrioritiesShell;
import 'package:plot/widget/confirm_modal.dart';
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
import 'package:plot/router.dart';
import 'package:plot/widget/spinner.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/widget/text_field_selection_theme.dart';
import 'command.dart';
import 'page_link.dart';
import 'upgrade.dart'
    show ManageSubscriptionCommand, RestorePurchasesCommand, ShowUpgradeOptions;
import 'logging.dart';

final appearanceCommands = StaticCommandGroup(
  title: 'Appearance',
  commands: [
    ChangeTheme(AppThemeMode.system),
    ChangeTheme(AppThemeMode.light),
    ChangeTheme(AppThemeMode.dark),
  ],
);

/// The subscription-related Settings entries (manage / upgrade / restore),
/// in display order, per the cross-platform gating matrix. Pure for testing.
List<Command> subscriptionCommandsFor({
  required SubscriptionInfo? subscription,
  required bool isAppStoreBuild,
}) {
  final cmds = <Command>[];
  final s = subscription;

  // Upgrade: only when there are tiers to offer for this state.
  if (s != null) {
    if (isAppStoreBuild) {
      final upgradePlans = ShowUpgradeOptions.plansFor(s);
      if (upgradePlans.isNotEmpty) {
        cmds.add(ShowUpgradeOptions(availablePlans: upgradePlans));
      }
    } else if (!s.canBuildTwists) {
      // Web/DMG: existing behavior — offer upgrade unless already top-tier.
      cmds.add(ShowUpgradeOptions());
    }
  }

  // Manage: app_store paid → Apple; stripe paid → web. Not for trial/free.
  if (s != null && s.hasPaidPlan && (s.isAppStore || s.isPaidStripe)) {
    cmds.add(ManageSubscriptionCommand(appStoreOrigin: s.isAppStore));
  }

  // Restore: always available on App Store builds.
  if (isAppStoreBuild) cmds.add(RestorePurchasesCommand());

  return cmds;
}

/// Build the App settings command group from [PrioritiesState].
///
/// [hasTeams] should be true when the user belongs to at least one team
/// (focuses are team-agnostic, so team membership is sourced from the API's
/// `/team` list by callers, not from priorities).
List<StaticCommandGroup> settingsCommandsFromState(
  PrioritiesState? prioritiesState, {
  bool hasTeams = false,
  bool showAllPriorities = false,
  String? email,
  SubscriptionInfo? subscription,
}) {
  final rootPriority = prioritiesState?.root;

  return settingsCommands(
    hasTeams: hasTeams,
    rootPriority: rootPriority,
    email: email,
    subscription: subscription,
    showAllPriorities: showAllPriorities,
  );
}

List<StaticCommandGroup> settingsCommands({
  bool hasTeams = false,
  Priority? rootPriority,
  String? email,
  SubscriptionInfo? subscription,
  bool showAllPriorities = false,
}) => [
  StaticCommandGroup(
    title: 'Settings',
    shortcut: platformSingleActivator(LogicalKeyboardKey.comma),
    commands: [
      ToggleArchived(showingArchived: showAllPriorities),
      ManageConnections(),
      ManageTwists(),
      ManageLinkedEmails(),
      ChangeAppearance(),
      if (NotificationService.isSupported &&
          !NotificationService.instance.isTokenRegistered)
        EnableNotifications(),
      if (rootPriority != null) ShowNotificationsSettings(),
      ChangeAiPreference(),
      // Only show Enter Behavior setting on devices with physical keyboards
      if (hasPhysicalKeyboard()) ChangeEnterBehavior(),
      if (hasTeams) ManageTeams(),
    ],
  ),
  StaticCommandGroup(
    title: 'App',
    commands: [
      ...subscriptionCommandsFor(
        subscription: subscription,
        isAppStoreBuild: UpgradeUi.isAppStoreBuild,
      ),
      if (rootPriority != null) HelpAndFeedback(rootPriority),
      OpenCopiedPageLink(),
      FullResync(),
      DeleteAccount(),
      CopyVersion(),
      SignOut(email: email),
    ],
  ),
];

final signedOutSettingsCommands = [
  StaticCommandGroup(title: 'Settings', commands: [ChangeAppearance()]),
  StaticCommandGroup(title: 'App', commands: [CopyVersion()]),
];

/// Builds the top-level settings command groups (the "Settings" and "App"
/// groups plus debug commands), async-fetching the user's orgs and
/// subscription from the API.
///
/// This is the single source of truth shared by [ShowSettings] (the desktop /
/// multi-panel settings modal) and `MorePage` (the single-panel "More" tab
/// that renders the same list as page content). Reading the blocs is optional
/// — when no [PrioritiesBloc]/[UserBloc]/[LocalPreferencesBloc] is in scope
/// (e.g. signed-out shells) the groups degrade gracefully.
Future<List<StaticCommandGroup>> buildSettingsGroups(
  BuildContext context,
) async {
  PrioritiesState? prioritiesState;
  UserState? userState;
  LocalPreferencesState? prefsState;
  if (context.mounted) {
    try {
      prioritiesState = context.read<PrioritiesBloc>().state;
      userState = context.read<UserBloc>().state;
      prefsState = context.read<LocalPreferencesBloc>().state;
    } catch (_) {}
  }

  final email = userState is UserReady ? userState.user.primaryEmail : null;
  final showAllPriorities = prefsState?.showAllPriorities ?? false;

  // Fetch orgs and subscription in parallel
  bool hasTeams = false;
  SubscriptionInfo? subscription;
  try {
    final results = await Future.wait([
      api.get<List<dynamic>>('/team'),
      UpgradeApi.getSubscription(),
    ]);
    final allOrgs = (results[0] as List<dynamic>).cast<Map<String, dynamic>>();
    hasTeams = allOrgs.isNotEmpty;
    subscription = results[1] as SubscriptionInfo;
  } catch (e, t) {
    // Non-critical — settings still work without these
    log.warning('Failed to fetch orgs/subscription for settings', e, t);
  }

  final groups = [
    if (prioritiesState != null)
      ...settingsCommandsFromState(
        prioritiesState,
        hasTeams: hasTeams,
        email: email,
        subscription: subscription,
        showAllPriorities: showAllPriorities,
      ),
  ];
  final debugCmds = buildDebugCommands();
  if (debugCmds != null) {
    groups.add(debugCmds);
  }
  return groups;
}

class ShowSettings extends ShowCommands {
  ShowSettings()
    : super(
        title: 'Settings',
        icon: PlotIcon.settings,
        commandsBuilder: _createBuilder(),
        shortcut: platformSingleActivator(LogicalKeyboardKey.comma),
      );

  static Future<Commands> Function(BuildContext) _createBuilder() {
    // Cache the build context state so a refresh (CommandRefresh) re-runs the
    // same async build. [buildSettingsGroups] reads the blocs itself, so the
    // closure simply re-invokes it against the captured context.
    BuildContext? cachedContext;

    return (context) async {
      cachedContext ??= context;
      final ctx = cachedContext!.mounted ? cachedContext! : context;
      final groups = await buildSettingsGroups(ctx);
      return Commands(groups: groups);
    };
  }
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

/// Permanently deletes the user's account. The server cancels Stripe billing,
/// bans the Clerk user for 14 days (preventing re-login during the grace
/// period), and schedules manual data purge. After the API succeeds the user
/// is signed out locally.
class DeleteAccount extends Command {
  DeleteAccount()
    : super(
        title: 'Delete account',
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
        icon: FontAwesomeIcons.userXmark,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final confirmed = await ConfirmModal(
      title: 'Delete account?',
      message:
          'Your account will be deactivated immediately and all your data '
          'will be permanently deleted within 14 days. This cannot be undone.',
      confirmLabel: 'Delete account',
      destructive: true,
    ).run(context);
    if (!confirmed) return const CommandSkipped();

    // Close the settings modal stack so the LoadingPage overlay covers the
    // app surface instead of layering on top of the menu the user just left.
    if (context.mounted) await Modal.popAll(context);

    // Insert a full-screen LoadingPage overlay at the root so the deletion
    // feels like a deliberate operation rather than a frozen menu.
    final rootCtx = navigatorKey?.currentContext;
    OverlayEntry? overlayEntry;
    if (rootCtx != null && rootCtx.mounted) {
      overlayEntry = OverlayEntry(
        builder: (_) => const Positioned.fill(
          child: LoadingPage(message: 'Deleting your account'),
        ),
      );
      Overlay.of(rootCtx, rootOverlay: true).insert(overlayEntry);
    }

    Object? deletionError;
    StackTrace? deletionStack;
    try {
      // Pair the API call with a 3-second floor so users see the loading
      // state instead of a flicker on fast networks.
      await Future.wait<void>([
        AccountApi.deleteAccount(),
        Future<void>.delayed(const Duration(seconds: 3)),
      ]);
    } catch (e, t) {
      deletionError = e;
      deletionStack = t;
    }

    if (deletionError != null) {
      overlayEntry?.remove();
      log.warning('Account deletion failed', deletionError, deletionStack);
      Tracker.captureException(deletionError, deletionStack);
      return CommandMessage(
        'Could not delete account. Please try again or contact support.',
        isError: true,
      );
    }

    try {
      await Base.signOut();
    } catch (e, t) {
      log.warning('Sign out after deletion failed', e, t);
      // Deletion already succeeded server-side; surface success regardless.
    }

    // Give RootProvider's BlocListener a frame to route to SignInRoute so
    // the toast lands on the sign-in page instead of the about-to-be-torn-
    // down signed-in shell.
    await WidgetsBinding.instance.endOfFrame;
    overlayEntry?.remove();

    final toastCtx = navigatorKey?.currentContext;
    if (toastCtx != null && toastCtx.mounted) {
      toastCtx.showToast(message: 'Account deleted');
    }

    return const CommandDone();
  }
}

class ManageTeams extends Command {
  ManageTeams()
    : super(
        title: 'Teams',
        // On App Store builds, omit the "billing" word to avoid linking
        // an in-app entry to externally-priced content (guideline 3.1.1).
        // The destination page is the same — Team admins navigate to
        // billing from there.
        description: UpgradeUi.isAppStoreBuild
            ? 'Members and domains for your teams.'
            : 'Members, domains, and billing for your teams.',
        icon: FontAwesomeIcons.building,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final orgs = await api.get<List<dynamic>>('/team');

      if (orgs.isEmpty) {
        return CommandMessage('You are not a member of any team');
      }

      if (orgs.length == 1) {
        final url = Uri.parse('${Env.siteRoot}/team/${orgs[0]['id']}');
        await launchUrl(url, mode: LaunchMode.externalApplication);
        return const CommandDone();
      }

      // Multiple orgs — show selection modal
      if (!context.mounted) return const CommandDone();
      final selected = await SelectModal.open<Map<String, dynamic>>(
        context,
        items: (search) async => [
          SelectGroup(title: 'Teams', items: orgs.cast<Map<String, dynamic>>()),
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
        final url = Uri.parse('${Env.siteRoot}/team/${selected.value['id']}');
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to open team management', e, t);
      return CommandMessage('Failed to open team management', isError: true);
    }
  }
}

// Upgrade flow now lives in lib/command/upgrade.dart and uses StoreKit IAP
// on App Store builds while keeping the web upgrade path for DMG / web.

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
    final prefs = await _fetchPreference();
    final builtinAiDisabled = prefs['builtin_ai_disabled'] == true;
    final twistAiDisabled = prefs['twist_ai_disabled'] == true;

    return FormData(
      title: 'AI preferences',
      groups: [
        StaticFormGroup(
          items: [
            FormSelect<bool>(
              key: 'builtinAiDisabled',
              label: 'Built-in AI',
              initialValue: builtinAiDisabled,
              hasInitialValue: true,
              titleBuilder: (v) => v == true ? 'Off' : 'On',
              items: (_) async => [false, true],
            ),
            FormSelect<bool>(
              key: 'twistAiDisabled',
              label: 'Twist AI',
              initialValue: twistAiDisabled,
              hasInitialValue: true,
              titleBuilder: (v) => v == true ? 'Off' : 'On',
              items: (_) async => [false, true],
            ),
          ],
        ),
        StaticFormGroup(
          items: [
            FormButton(
              key: 'save',
              isPrimary: true,
              buildCommand: (values) => _SaveAiPreference(
                builtinAiDisabled: values['builtinAiDisabled'] as bool? ?? false,
                twistAiDisabled: values['twistAiDisabled'] as bool? ?? false,
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
        title: 'Notifications',
        subtitle: NotificationService.instance.isPermissionDenied
            ? 'Off — enable in device settings'
            : 'Off — tap to turn on',
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
    NotificationService.instance.openSystemNotificationSettings();
    return CommandMessage(
      'Please enable notifications in your device settings, then return to Plot.',
    );
  }
}

/// Fetch AI preference selections for the current user.
Future<Map<String, dynamic>> _fetchPreference() async {
  try {
    return await api.get<Map<String, dynamic>>('/ai-preference');
  } catch (_) {
    return {'builtin_ai_disabled': false, 'twist_ai_disabled': false};
  }
}

class _SaveAiPreference extends Command {
  _SaveAiPreference({
    required this.builtinAiDisabled,
    required this.twistAiDisabled,
  }) : super(
         title: 'Save',
         icon: FontAwesomeIcons.check,
         eventObject: EventObject.settings,
         eventAction: EventAction.updated,
       );

  final bool builtinAiDisabled;
  final bool twistAiDisabled;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/ai-preference',
        body: {
          'builtinAiDisabled': builtinAiDisabled,
          'twistAiDisabled': twistAiDisabled,
        },
      );

      if (context.mounted) {
        await context.read<SettingsBloc>().setAiEnabled(
          !(builtinAiDisabled && twistAiDisabled),
        );

        // If twist AI was just disabled, archive twists that require AI.
        if (twistAiDisabled) {
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
      return CommandMessage('Failed to save: ${e.toString()}', isError: true);
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
        final twists = await TwistApi.getAllTwists();
        // Find twists that require AI (have ai prompt permission)
        final aiTwists = twists.where(
          (t) =>
              t.permissions?.hasPermission(
                'ai',
                'prompt',
                PermissionFlag.use,
              ) ==
              true,
        );

        // Get active local twist_instances to find IDs. Twists are now
        // workspace-level, so this is not filtered by priority.
        final localTwists = await TwistInstance.get(archived: false);

        for (final aiTwist in aiTwists) {
          // Find matching local twist_instance
          final localTwist = localTwists
              .where((lt) => lt.twistId.toString() == aiTwist.id)
              .firstOrNull;

          if (localTwist != null) {
            await TwistApi.archiveAndRemoveTwist(localTwist.id.toString());
            await Store.get.save(
              TwistInstance.table,
              localTwist.copyWith(
                archivedAt: Value(DateTime.now()),
                updatedAt: DateTime.now(),
              ),
              TwistInstancesBase(),
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

class HelpAndFeedback extends Command {
  HelpAndFeedback(this.rootPriority)
    : super(
        title: 'Help and feedback',
        subtitle: 'Ask for help or share feedback with the Plot team',
        icon: PlotIcon.help,
        eventObject: EventObject.commandBar,
        eventAction: EventAction.opened,
      );

  /// The user's Inbox (root). Help & Feedback opens a new thread here,
  /// addressed to the Plot Team group (see [NewThreadPage.feedback]).
  final Priority rootPriority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Open the final compose screen addressed to the Plot Team. Navigation is
    // handled by [OpenFeedbackThread.go] (which drives the Activity-tab inner
    // stack so it works in single- AND multi-panel) — returning it via the
    // CommandRoute dispatch also closes any open settings modal first.
    return OpenFeedbackThread(rootPriority.id.toShortString());
  }
}

/// Navigates to the new-thread compose flow in Help & Feedback mode.
///
/// Subclasses [CommandRoute] so the command/modal dispatch closes open modals
/// (`Modal.popAll`) before navigating, but overrides [go] to drive the
/// Activity-tab inner stack via [PrioritiesShell.openFeedbackThread] instead of
/// a plain `navigate`: `navigate(PriorityRoute(children: [NewThreadRoute]))`
/// silently drops the inner child once PriorityRoute is already mounted, which
/// is why the previous implementation left the user on whatever screen they
/// were viewing. The [PriorityRoute] passed to `super` is only a placeholder so
/// `route` stays non-null; [go] never uses it.
class OpenFeedbackThread extends CommandRoute {
  OpenFeedbackThread(this.rootPriorityIdString)
    : super(PriorityRoute(priorityIdString: rootPriorityIdString));

  final String rootPriorityIdString;

  @override
  Future<void> go(BuildContext context) async {
    if (!context.mounted) return;
    PrioritiesShell.openFeedbackThread(context, rootPriorityIdString);
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
                        Flexible(
                          child: Text(
                            primaryEmail,
                            style: context.theme.typography.md,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
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
  final _otpController = FOtpController();
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
                      FOtpField(
                        key: ValueKey(_otpResetCounter),
                        control: FOtpFieldControl.managed(
                          controller: _otpController,
                          onChange: (value) {
                            if (value.text.length == 6) {
                              FocusManager.instance.primaryFocus?.unfocus();
                              _handleVerifyCode();
                            }
                          },
                        ),
                        autofocus: true,
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
              builder: fieldSelectionBuilder,
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

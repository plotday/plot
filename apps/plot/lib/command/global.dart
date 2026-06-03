import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/api/api.dart' as api;
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/user.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/developer_mode.dart';
import 'command.dart';

class GlobalShortcuts extends StatefulWidget {
  const GlobalShortcuts({required this.child, super.key});

  final Widget child;

  @override
  State<GlobalShortcuts> createState() => _GlobalShortcutsState();
}

class _GlobalShortcutsState extends State<GlobalShortcuts> {
  SubscriptionInfo? _subscription;
  List<Map<String, dynamic>> _adminOrgs = const [];
  bool _hasTeams = false;
  bool _fetchedSubscription = false;
  bool _registeredSyncCallback = false;

  void _fetchSubscription() async {
    if (_fetchedSubscription) return;
    _fetchedSubscription = true;
    _registerSyncCallback();
    try {
      final results = await Future.wait([
        UpgradeApi.getSubscription(),
        api.get<List<dynamic>>('/team'),
      ]);
      if (mounted) {
        setState(() {
          _subscription = results[0] as SubscriptionInfo;
          final orgs = (results[1] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          _hasTeams = orgs.isNotEmpty;
          _adminOrgs = orgs.where((o) => o['role'] == 'admin').toList();
        });
      }
    } catch (_) {
      // Non-critical — commands still work without subscription info
    }
  }

  void _registerSyncCallback() {
    if (_registeredSyncCallback) return;
    _registeredSyncCallback = true;
    Store.get.onSubscriptionChanged = _onSubscriptionChanged;
  }

  void _onSubscriptionChanged() async {
    try {
      final results = await Future.wait([
        UpgradeApi.getSubscription(),
        api.get<List<dynamic>>('/team'),
      ]);
      if (mounted) {
        setState(() {
          _subscription = results[0] as SubscriptionInfo;
          final orgs = (results[1] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          _hasTeams = orgs.isNotEmpty;
          _adminOrgs = orgs.where((o) => o['role'] == 'admin').toList();
        });
      }
    } catch (_) {
      // Non-critical
    }
  }

  List<StaticCommandGroup> _getCommands({
    required bool signedIn,
    PrioritiesState? prioritiesState,
    bool showAllPriorities = false,
    String? email,
  }) {
    // When signed out, only show settings commands (and debug commands in debug mode)
    if (!signedIn) {
      final commands = [...signedOutSettingsCommands];
      final debugCmds = buildDebugCommands();
      if (debugCmds != null) {
        commands.add(debugCmds);
      }
      return commands;
    }

    // When signed in, show all commands
    final commands = [
      StaticCommandGroup(
        title: 'Navigation',
        commands: [PageBackCommand()],
      ),
      StaticCommandGroup(
        title: 'Focuses',
        commands: [PickCurrentPriority(), NewFocus()],
      ),
      ...settingsCommandsFromState(
        prioritiesState,
        hasTeams: _hasTeams,
        showAllPriorities: showAllPriorities,
        email: email,
        adminOrgs: _adminOrgs,
        subscription: _subscription,
      ),
    ];

    // Add debug commands in debug mode or developer mode
    final debugCmds = buildDebugCommands();
    if (debugCmds != null) {
      commands.add(debugCmds);
    }

    return commands;
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UserBloc, UserState>(
      builder: (context, userState) {
        final signedIn = userState is UserReady;

        if (!signedIn) {
          _fetchedSubscription = false;
          _registeredSyncCallback = false;
          _subscription = null;
          _adminOrgs = const [];
          return CommandScope(
            commandsBuilder: () => _getCommands(signedIn: false),
            listenable: DeveloperMode.notifier,
            child: widget.child,
          );
        }

        _fetchSubscription();

        return BlocBuilder<PrioritiesBloc, PrioritiesState>(
          builder: (context, prioritiesState) {
            return BlocBuilder<LocalPreferencesBloc, LocalPreferencesState>(
              builder: (context, localPrefsState) {
                return CommandScope(
                  commandsBuilder: () => _getCommands(
                    signedIn: true,
                    prioritiesState: prioritiesState,
                    showAllPriorities: localPrefsState.showAllPriorities,
                    email: userState.user.primaryEmail,
                  ),
                  listenable: DeveloperMode.notifier,
                  child: widget.child,
                );
              },
            );
          },
        );
      },
    );
  }
}

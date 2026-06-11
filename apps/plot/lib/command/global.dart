import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/api/upgrade_api.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/subscription_service.dart';
import 'package:plot/state/user.dart';
import 'package:plot/util/developer_mode.dart';
import 'command.dart';

class GlobalShortcuts extends StatefulWidget {
  const GlobalShortcuts({required this.child, super.key});

  final Widget child;

  @override
  State<GlobalShortcuts> createState() => _GlobalShortcutsState();
}

class _GlobalShortcutsState extends State<GlobalShortcuts> {
  bool _wasSignedIn = false;

  List<StaticCommandGroup> _getCommands({
    required bool signedIn,
    PrioritiesState? prioritiesState,
    bool showAllPriorities = false,
    String? email,
    SubscriptionInfo? subscription,
    List<Map<String, dynamic>> adminOrgs = const [],
    bool hasTeams = false,
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
        commands: [PickCurrentPriority(), AddFocus()],
      ),
      ...settingsCommandsFromState(
        prioritiesState,
        hasTeams: hasTeams,
        showAllPriorities: showAllPriorities,
        email: email,
        adminOrgs: adminOrgs,
        subscription: subscription,
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
          if (_wasSignedIn) {
            _wasSignedIn = false;
            SubscriptionService.instance.reset();
          }
          return CommandScope(
            commandsBuilder: () => _getCommands(signedIn: false),
            listenable: DeveloperMode.notifier,
            child: widget.child,
          );
        }

        // Loads the initial snapshot and wires broadcast/reconnect/refocus
        // refresh + the plan-up toast. Both are idempotent / cheap; start()
        // self-guards so calling it each rebuild is fine.
        _wasSignedIn = true;
        SubscriptionService.instance.start();

        return BlocBuilder<PrioritiesBloc, PrioritiesState>(
          builder: (context, prioritiesState) {
            return BlocBuilder<LocalPreferencesBloc, LocalPreferencesState>(
              builder: (context, localPrefsState) {
                return ValueListenableBuilder<SubscriptionSnapshot>(
                  valueListenable: SubscriptionService.instance.notifier,
                  builder: (context, snapshot, _) {
                    return CommandScope(
                      commandsBuilder: () => _getCommands(
                        signedIn: true,
                        prioritiesState: prioritiesState,
                        showAllPriorities: localPrefsState.showAllPriorities,
                        email: userState.user.primaryEmail,
                        subscription: snapshot.subscription,
                        adminOrgs: snapshot.adminOrgs,
                        hasTeams: snapshot.hasTeams,
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
      },
    );
  }
}

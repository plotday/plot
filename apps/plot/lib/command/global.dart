import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/api/upgrade_api.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/priorities.dart';
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
  SubscriptionInfo? _subscription;
  bool _fetchedSubscription = false;

  void _fetchSubscription() async {
    if (_fetchedSubscription) return;
    _fetchedSubscription = true;
    try {
      final subscription = await UpgradeApi.getSubscription();
      if (mounted) setState(() => _subscription = subscription);
    } catch (_) {
      // Non-critical — commands still work without subscription info
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
      final commands = [signedOutSettingsCommands];
      final debugCmds = buildDebugCommands();
      if (debugCmds != null) {
        commands.add(debugCmds);
      }
      return commands;
    }

    // When signed in, show all commands
    final commands = [
      StaticCommandGroup(
        title: 'Priorities',
        commands: [PickCurrentPriority(), NewPriority()],
      ),
      settingsCommandsFromState(
        prioritiesState,
        showAllPriorities: showAllPriorities,
        email: email,
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
          _subscription = null;
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

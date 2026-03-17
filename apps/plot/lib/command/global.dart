import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/user.dart';
import 'command.dart';

class GlobalShortcuts extends StatelessWidget {
  const GlobalShortcuts({required this.child, super.key});

  final Widget child;

  List<StaticCommandGroup> _getCommands({
    required bool signedIn,
    PrioritiesState? prioritiesState,
    bool showAllPriorities = false,
    String? email,
  }) {
    // When signed out, only show settings commands (and debug commands in debug mode)
    if (!signedIn) {
      final commands = [signedOutSettingsCommands];
      if (kDebugMode && debugCommands != null) {
        commands.add(debugCommands!);
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
      ),
    ];

    // Add debug commands in debug mode
    if (kDebugMode && debugCommands != null) {
      commands.add(debugCommands!);
    }

    return commands;
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UserBloc, UserState>(
      builder: (context, userState) {
        final signedIn = userState is UserReady;

        if (!signedIn) {
          return CommandScope(
            commands: _getCommands(signedIn: false),
            child: child,
          );
        }

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
                  child: child,
                );
              },
            );
          },
        );
      },
    );
  }
}

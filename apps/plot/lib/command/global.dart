import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/user.dart';
import 'command.dart';

class GlobalShortcuts extends StatelessWidget {
  const GlobalShortcuts({required this.child, super.key});

  final Widget child;

  List<StaticCommandGroup> _getCommands(bool signedIn) {
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
      settingsCommands,
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
      builder: (context, state) {
        // Determine if signed in based on UserState
        final signedIn = state is UserReady;

        return CommandScope(commands: _getCommands(signedIn), child: child);
      },
    );
  }
}

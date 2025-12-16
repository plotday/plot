import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/user.dart';
import 'command.dart';

class GlobalShortcuts extends StatelessWidget {
  const GlobalShortcuts({required this.child, super.key});

  final Widget child;

  List<StaticCommandGroup> _getCommands(bool signedIn) {
    // When signed out, only show settings commands
    if (!signedIn) {
      return [signedOutSettingsCommands];
    }

    // When signed in, show all commands
    return [
      StaticCommandGroup(
        title: 'Priorities',
        commands: [PickCurrentPriority(), NewPriority()],
      ),
      settingsCommands,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UserBloc, UserState>(
      builder: (context, state) {
        // Determine if signed in based on UserState
        final signedIn =
            state is UserReady ||
            state is UserWaitlisted ||
            state is UserPasswordRequired;

        return CommandScope(commands: _getCommands(signedIn), child: child);
      },
    );
  }
}

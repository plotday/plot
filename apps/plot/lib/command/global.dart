import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/user.dart';
import 'package:plot/util/platform.dart';
import 'command.dart';
import 'page_link.dart';

bool _hasOrganizations(PrioritiesState? state) =>
    state != null &&
    state.priorities.any((p) => p.organizationId != null);

class GlobalShortcuts extends StatelessWidget {
  const GlobalShortcuts({required this.child, super.key});

  final Widget child;

  List<StaticCommandGroup> _getCommands({
    required bool signedIn,
    PrioritiesState? prioritiesState,
    bool showAllPriorities = false,
  }) {
    // When signed out, only show settings commands (and debug commands in debug mode)
    if (!signedIn) {
      final commands = [signedOutSettingsCommands];
      if (kDebugMode && debugCommands != null) {
        commands.add(debugCommands!);
      }
      return commands;
    }

    // Extract @plot priority commands
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
          } else if (child.key?.startsWith('@help-feedback') == true) {
            helpFeedbackCmd = OpenHelpFeedback(child);
          } else if (child.key == '@whats-new') {
            whatsNewCmd = OpenWhatsNew(child);
          }
        }
      }
    }

    // When signed in, show all commands
    final commands = [
      StaticCommandGroup(
        title: 'Priorities',
        commands: [PickCurrentPriority(), NewPriority()],
      ),
      StaticCommandGroup(
        title: 'App',
        shortcut: settingsCommands().shortcut,
        commands: [
          if (gettingStartedCmd != null) gettingStartedCmd,
          ManageConnections(),
          ManageTwists(),
          if (_hasOrganizations(prioritiesState))
            ManageOrganizations(),
          CopyPageLink(),
          OpenCopiedPageLink(),
          ChangeAppearance(),
          if (hasPhysicalKeyboard()) ChangeEnterBehavior(),
          if (whatsNewCmd != null) whatsNewCmd,
          if (helpFeedbackCmd != null) helpFeedbackCmd,
          FullResync(),
          CopyVersion(),
          SignOut(),
        ],
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

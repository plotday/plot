import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'list_tile.dart';
import 'modal.dart';
import 'logging.dart';
import 'select_modal.dart';

class CommandModal {
  factory CommandModal(Commands commands, {required BuildContext rootContext}) {
    return CommandModal._(commands, rootContext);
  }

  CommandModal._(this.commands, this.rootContext);

  final Commands commands;
  final BuildContext rootContext;

  Future<CommandReturn> run(BuildContext context) async {
    final baseCommandList = await commands.list();
    if (!context.mounted) return CommandSkipped();
    final result = await SelectModal.open<Command>(
      context,
      items: (search) async {
        final commandsList = (search == null || search.isEmpty)
            ? baseCommandList
            : await commands.list(search: search);
        return commandsList
            .map(
              (cg) => SelectGroup<Command>(
                title: cg.title,
                items: cg.commands,
                infoBuilder: cg.infoBuilder,
              ),
            )
            .toList();
      },
      itemBuilder: (command) => ListTile(command: command),
      prompt: commands.prompt,
      onSelect: _handleCommandSelection,
    );

    return result.present ? const CommandDone() : const CommandSkipped();
  }

  Future<bool> _handleCommandSelection(
    BuildContext modalContext,
    Command command,
    String searchText,
  ) async {
    final result = await _executeCommand(command, modalContext);

    // Keep SelectModal open if command was skipped or if there was an error
    if (result is CommandSkipped ||
        (result is CommandMessage && result.isError)) {
      return false;
    }

    // If command returned CommandRoute, modals are already closed by _executeCommand
    if (result is CommandRoute) {
      return false;
    }

    // Close SelectModal if command completed successfully
    return true;
  }

  Future<CommandReturn> _executeCommand(
    Command command,
    BuildContext modalContext,
  ) async {
    try {
      // Use rootContext if mounted, otherwise fall back to modal context
      final commandContext = rootContext.mounted ? rootContext : modalContext;
      final result = await command.run(commandContext);

      if (!modalContext.mounted) return const CommandSkipped();

      if (result is CommandSkipped) {
        return result;
      } else if (result is CommandMessage) {
        if (result.isError) {
          // Show error toast
          showFToast(
            context: modalContext,
            alignment: FToastAlignment.topEnd,
            title: const Text('Error'),
            description: Text(result.message),
            duration: const Duration(seconds: 3),
          );
          return result;
        } else {
          // Show success toast
          showFToast(
            context: modalContext,
            alignment: FToastAlignment.topEnd,
            title: Text(result.message),
            duration: const Duration(seconds: 2),
          );
        }
      }

      // Only close modals and navigate for CommandRoute
      if (result is CommandRoute) {
        Modal.popAll(modalContext);
        if (modalContext.mounted) {
          final routeContext = rootContext.mounted ? rootContext : modalContext;
          result.go(routeContext);
        }
      }
    } catch (e, stackTrace) {
      log.warning('Error executing command', e, stackTrace);
      showFToast(
        context: modalContext,
        alignment: FToastAlignment.topEnd,
        title: const Text('Error'),
        description: const Text('Something went wrong'),
        duration: const Duration(seconds: 3),
      );
      return const CommandMessage('Something went wrong', isError: true);
    }
    return const CommandDone();
  }
}

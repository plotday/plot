import 'package:flutter/widgets.dart';

import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/shortcut.dart';
import 'list_tile.dart';
import 'modal.dart';
import 'toast.dart';
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
                hint: formatShortcut(cg.shortcut),
              ),
            )
            .toList();
      },
      itemBuilder: (command) =>
          ListTile(command: command, noRun: true, showShortcut: true),
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
          modalContext.showToast(
            title: result.title,
            message: result.message,
            isError: true,
          );
          return result;
        } else {
          // Show success toast in root context (survives modal closure)
          final toastContext = rootContext.mounted ? rootContext : modalContext;
          toastContext.showToast(
            title: result.title,
            message: result.message,
          );
        }
      }

      // Close the modal before navigating
      if (result is CommandRoute) {
        Modal.popAll(modalContext);
        if (modalContext.mounted) {
          final routeContext = rootContext.mounted ? rootContext : modalContext;
          result.go(routeContext);
        }
      }
    } catch (e, stackTrace) {
      log.warning('Error executing command', e, stackTrace);

      final (title, message) = switch (e) {
        ApiException() => (e.title, e.description),
        NetworkException() => ('Network Error', e.message),
        _ => ('Error', 'Something went wrong'),
      };

      modalContext.showToast(
        title: title,
        message: message,
        isError: true,
      );
      return CommandMessage(message, title: title, isError: true);
    }
    return const CommandDone();
  }
}

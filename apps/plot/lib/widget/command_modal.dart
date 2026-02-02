import 'package:flutter/widgets.dart';

import 'package:plot/command/command.dart';
import 'package:plot/util/shortcut.dart';
import 'form.dart';
import 'list_tile.dart';
import 'modal.dart';
import 'select_modal.dart';

class CommandModal {
  factory CommandModal(Commands commands, {required BuildContext rootContext}) {
    return CommandModal._(commands, rootContext);
  }

  CommandModal._(this.commands, this.rootContext);

  final Commands commands;
  final BuildContext rootContext;
  Future<void> Function()? _refreshCallback;
  final Map<String, ListTileController> _controllers = {};

  /// Stable key for controller lookup that survives commands.list() returning new instances.
  static String _controllerKey(Command command) =>
      '${command.runtimeType}:${command.title}:${command.eventObject}:${command.eventAction}';

  Future<CommandReturn> run(BuildContext context) async {
    if (!context.mounted) return CommandSkipped();
    // Clear previous controllers
    _controllers.clear();
    final result = await SelectModal.open<Command>(
      context,
      items: (search) async {
        // Always fetch fresh data to ensure refresh works correctly
        final commandsList = await commands.list(search: search);
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
      itemBuilder: (command) {
        // Get or create controller for this command (reuse if it exists)
        final controller = _controllers.putIfAbsent(
          _controllerKey(command),
          () => ListTileController(),
        );

        // Commands that show modals need modalContext to display UI
        // All other commands get rootContext for provider access
        final wrappedCommand = command is ShowCommands ||
                command is ShowForm ||
                command is ShowPage
            ? command
            : CommandWrapper(
                command,
                run: (cmd, _) => cmd.run(rootContext),
              );

        return ListTile(
          controller: controller,
          command: wrappedCommand,
          showShortcut: true,
          onRun: (context, result) async {
            // Handle the command result using shared Modal handler
            final shouldClose = await Modal.handleCommandResult(
              context,
              result,
              command,
              rootContext: rootContext,
              onRefresh: _refreshCallback,
            );

            // Close modal if handler indicates we should
            if (shouldClose && context.mounted) {
              Modal.pop(context, Value(command));
            }

            return shouldClose;
          },
        );
      },
      prompt: commands.prompt,
      emptyMessage: commands.emptyMessage,
      onSelect: (modalContext, command, searchText) async {
        // Get the controller for this command and call run()
        // This ensures spinner state management for Enter key path
        final key = _controllerKey(command);
        final controller = _controllers[key];

        // Only use controller path if it's attached (ListTile rendered and not disposed)
        if (controller != null && controller.isAttached) {
          final result = await controller.run();
          // Return false because onRun already closed the modal if needed
          return false;
        }

        // Controller doesn't exist or not attached — run command directly without spinner
        final context = command is ShowCommands ||
                command is ShowForm ||
                command is ShowPage
            ? modalContext
            : rootContext;
        final result = await command.run(context);

        if (!modalContext.mounted) return false;

        final shouldClose = await Modal.handleCommandResult(
          modalContext,
          result,
          command,
          rootContext: rootContext,
          onRefresh: _refreshCallback,
        );

        if (shouldClose && modalContext.mounted) {
          Modal.pop(modalContext, Value(command));
        }

        return false;
      },
      onRefreshNeeded: (refresh) {
        _refreshCallback = refresh;
      },
    );

    return result.present ? const CommandDone() : const CommandSkipped();
  }
}

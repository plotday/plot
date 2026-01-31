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
  final Map<Command, ListTileController> _controllers = {};

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
          command,
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
        final controller = _controllers[command];

        // Only use controller path if it's attached (ListTile rendered and not disposed)
        if (controller != null && controller.isAttached) {
          // The controller calls ListTile's run() which:
          // 1. Shows spinner
          // 2. Executes command
          // 3. Calls onRun callback (which calls Modal.handleCommandResult() AND Modal.pop())
          // 4. Returns the bool from onRun indicating whether modal was closed
          await controller.run();
          // Return false because onRun already closed the modal if needed
          // This prevents _selectItem from calling Navigator.pop() again
          return false;
        }

        // Controller doesn't exist or not attached (item not yet rendered or already disposed)
        // Run the command directly without spinner
        // Commands that show modals need modalContext, others need rootContext for provider access
        final context = command is ShowCommands ||
                command is ShowForm ||
                command is ShowPage
            ? modalContext
            : rootContext;
        final result = await command.run(context);

        if (!modalContext.mounted) {
          return false;
        }

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

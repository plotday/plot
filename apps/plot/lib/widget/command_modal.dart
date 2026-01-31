import 'package:flutter/widgets.dart';

import 'package:plot/command/command.dart';
import 'package:plot/util/shortcut.dart';
import 'list_tile.dart';
import 'modal.dart';
import 'select_modal.dart';
import 'logging.dart';

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
        final isNew = !_controllers.containsKey(command);
        final controller = _controllers.putIfAbsent(
          command,
          () => ListTileController(),
        );
        if (isNew) {
          log.info("Created NEW controller for command: ${command.title}");
        } else {
          log.info("Reusing existing controller for command: ${command.title}");
        }

        return ListTile(
          controller: controller,
          command: command,
          showShortcut: true,
          onRun: (context, result) async {
            log.info("ListTile.onRun called for ${command.title}");
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
        log.info("CommandModal.onSelect called for command: ${command.title}");

        // Get the controller for this command and call run()
        // This ensures spinner state management for Enter key path
        final controller = _controllers[command];
        log.info(
          "Controller exists: ${controller != null}, isAttached: ${controller?.isAttached}",
        );

        // Only use controller path if it's attached (ListTile rendered and not disposed)
        if (controller != null && controller.isAttached) {
          log.info("Using controller path for ${command.title}");
          // The controller calls ListTile's _runAndGetModalResult() which:
          // 1. Shows spinner
          // 2. Executes command
          // 3. Calls onRun callback (which calls Modal.handleCommandResult() AND Modal.pop())
          // 4. Returns the bool from onRun indicating whether modal was closed
          await controller.run();
          log.info("Controller.run() completed for ${command.title}");
          // Return false because onRun already closed the modal if needed
          // This prevents _selectItem from calling Navigator.pop() again
          return false;
        }

        // Controller doesn't exist or not attached (item not yet rendered or already disposed)
        // Run the command directly without spinner
        log.info(
          "Using direct path for ${command.title} (controller null or not attached)",
        );
        final result = await command.run(modalContext);
        log.info("Command.run() completed with result: ${result.runtimeType}");

        if (!modalContext.mounted) {
          log.info("Context not mounted, returning false");
          return false;
        }

        final shouldClose = await Modal.handleCommandResult(
          modalContext,
          result,
          command,
          rootContext: rootContext,
          onRefresh: _refreshCallback,
        );
        log.info(
          "Modal.handleCommandResult returned shouldClose: $shouldClose",
        );

        if (shouldClose && modalContext.mounted) {
          log.info("Closing modal for ${command.title}");
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

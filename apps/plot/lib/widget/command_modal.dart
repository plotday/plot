import 'dart:async';
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
  Future<void> Function()? _refreshCallback;

  // Track which command is running (for showing spinner)
  final ValueNotifier<Command?> _runningCommand = ValueNotifier(null);
  Timer? _spinnerDelayTimer;

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
      itemBuilder: (command) {
        // Wrap with ValueListenableBuilder to show spinner for running command
        return ValueListenableBuilder<Command?>(
          valueListenable: _runningCommand,
          builder: (context, runningCommand, child) {
            return ListTile(
              command: command,
              noRun: true,
              showShortcut: true,
              isRunning: runningCommand == command,
            );
          },
        );
      },
      prompt: commands.prompt,
      onSelect: _handleCommandSelection,
      emptyMessage: commands.emptyMessage,
      onRefreshNeeded: (refresh) {
        _refreshCallback = refresh;
      },
    );

    // Clean up on modal close
    _spinnerDelayTimer?.cancel();
    _runningCommand.value = null;

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

    // Handle CommandRefresh - show message, refresh commands, keep modal open
    if (result is CommandRefresh) {
      // Show success message if provided
      if (result.message != null) {
        final toastContext = rootContext.mounted ? rootContext : modalContext;
        if (toastContext.mounted) {
          toastContext.showToast(title: result.title, message: result.message!);
        }
      }

      // Trigger refresh
      await _refreshCallback?.call();

      return false; // Keep modal open
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
    // Start timer to show spinner after 100ms
    _spinnerDelayTimer = Timer(const Duration(milliseconds: 100), () {
      if (modalContext.mounted) {
        _runningCommand.value = command;
      }
    });

    try {
      // Use rootContext if mounted, otherwise fall back to modal context
      final commandContext = rootContext.mounted ? rootContext : modalContext;
      final result = await command.run(commandContext);

      if (!modalContext.mounted) return const CommandSkipped();

      if (result is CommandSkipped) {
        return result;
      } else if (result is CommandRefresh) {
        // Return CommandRefresh as-is so it can be handled by _handleCommandSelection
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
          toastContext.showToast(title: result.title, message: result.message);
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

      modalContext.showToast(title: title, message: message, isError: true);
      return CommandMessage(message, title: title, isError: true);
    } finally {
      // Always clean up timer and running state
      _spinnerDelayTimer?.cancel();
      _runningCommand.value = null;
    }
    return const CommandDone();
  }

  /// Clean up resources when CommandModal is no longer needed
  void dispose() {
    _spinnerDelayTimer?.cancel();
    _runningCommand.dispose();
  }
}

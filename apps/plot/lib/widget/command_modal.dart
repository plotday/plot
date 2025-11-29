import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/analytics/analytics.dart';
import 'list_tile.dart';
import 'modal.dart';
import 'button.dart';
import 'icon.dart';
import 'logging.dart';
import 'select_modal.dart';

// Simple back command for nested navigation in CommandModal
class _BackCommand extends Command {
  _BackCommand()
    : super(
        title: 'Back',
        eventObject: EventObject.dialog,
        eventAction: EventAction.clicked,
        icon: PlotIcon.back,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return const CommandDone();
  }
}

class CommandModal extends Modal {
  factory CommandModal(Commands commands, {required BuildContext rootContext}) {
    // Cache the _CommandModalContent widget so it's not recreated on modal rebuilds
    final content = _CommandModalContent(
      commands: commands,
      rootContext: rootContext,
    );
    return CommandModal._(content, commands);
  }

  CommandModal._(_CommandModalContent content, Commands commands)
    : super(
        padding: const EdgeInsets.all(0),
        builder: (_) => content,
        key: ObjectKey(commands),
      );

  Future<CommandReturn> run(BuildContext context) async {
    final value = await show<CommandReturn>(context);
    return value.present ? value.value : const CommandSkipped();
  }
}

class _CommandModalContent extends StatefulWidget {
  const _CommandModalContent({
    required this.commands,
    required this.rootContext,
  });

  final Commands commands;
  final BuildContext rootContext;

  @override
  _CommandModalContentState createState() => _CommandModalContentState();
}

class _CommandModalContentState extends State<_CommandModalContent> {
  late Commands commands = widget.commands;
  final List<Widget Function(BuildContext)> _navigationStack = [];
  bool _isSelectModalOpen = false;

  @override
  void initState() {
    super.initState();
    // Open SelectModal after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showCommandList();
    });
  }

  Future<void> _showCommandList() async {
    if (!mounted || _isSelectModalOpen) return;
    _isSelectModalOpen = true;

    final result = await SelectModal.open<Command>(
      context,
      items: (search) async {
        final commandsList = await commands.list(search: search);
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

    _isSelectModalOpen = false;

    // Close the CommandModal in all cases (whether a command was selected or dismissed)
    // Use rootContext instead of local context since it may be unmounted after SelectModal closes
    if (_navigationStack.isEmpty && widget.rootContext.mounted) {
      // Pop with the appropriate result type
      if (result.present) {
        // A command was executed, pop with CommandDone
        Modal.pop<CommandReturn>(widget.rootContext, const Value(CommandDone()));
      } else {
        // SelectModal was dismissed, pop with absent
        Modal.pop<CommandReturn>(widget.rootContext, const Value.absent());
      }
    }
  }

  Future<bool> _handleCommandSelection(
    BuildContext modalContext,
    Command command,
    String searchText,
  ) async {
    final result = await _executeCommand(command, modalContext);

    // Keep SelectModal open if command was skipped (e.g., nested modal was canceled)
    // or if there was an error
    if (result is CommandSkipped || (result is CommandMessage && result.isError)) {
      return false;
    }

    // If command returned CommandRoute, modals are already closed by _executeCommand
    // so keep SelectModal open (it's already closed anyway)
    if (result is CommandRoute) {
      return false;
    }

    // Close SelectModal if command completed successfully and no nested page is showing
    return _navigationStack.isEmpty;
  }

  bool _popPage() {
    if (_navigationStack.isEmpty) {
      return false;
    }
    setState(() {
      _navigationStack.removeLast();
    });
    return true;
  }

  bool get _isShowingNestedPage => _navigationStack.isNotEmpty;

  Future<CommandReturn> _executeCommand(
    Command command,
    BuildContext modalContext,
  ) async {
    try {
      // Use rootContext if mounted, otherwise fall back to modal context
      final commandContext = widget.rootContext.mounted
          ? widget.rootContext
          : modalContext;
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
          final routeContext = widget.rootContext.mounted
              ? widget.rootContext
              : modalContext;
          result.go(routeContext);
        }
      }
    } catch (e, stackTrace) {
      log.warning('Error executing command', e, stackTrace);
      if (mounted) {
        showFToast(
          context: modalContext,
          alignment: FToastAlignment.topEnd,
          title: const Text('Error'),
          description: const Text('Something went wrong'),
          duration: const Duration(seconds: 3),
        );
      }
      return const CommandMessage('Something went wrong', isError: true);
    }
    return const CommandDone();
  }

  @override
  Widget build(BuildContext context) {
    // If showing a nested page, render it instead of the command list
    if (_isShowingNestedPage) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) {
            _popPage();
          }
        },
        child: Column(
          children: [
            // Back button header for nested pages
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: context.theme.colors.border,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Button.icon(
                    CommandWrapper(
                      _BackCommand(),
                      run: (_, _) async {
                        _popPage();
                        // Re-show the command list after popping
                        if (_navigationStack.isEmpty) {
                          _showCommandList();
                        }
                        return const CommandDone();
                      },
                    ),
                  ),
                  const Spacer(),
                ],
              ),
            ),
            Expanded(child: _navigationStack.last(context)),
          ],
        ),
      );
    }

    // When not showing nested page, SelectModal is shown as a separate modal
    // This build method just returns an empty container as placeholder
    return const SizedBox.shrink();
  }
}

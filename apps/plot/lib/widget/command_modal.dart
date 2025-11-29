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

class CommandModal {
  CommandModal(Commands commands, {required BuildContext rootContext})
    : _commands = commands,
      _rootContext = rootContext;

  final Commands _commands;
  final BuildContext _rootContext;

  Future<CommandReturn> run(BuildContext context) async {
    // Modal handles multiPanel logic automatically
    final modal = Modal(
      padding: const EdgeInsets.all(0),
      builder: (_) =>
          _CommandModalContent(commands: _commands, rootContext: _rootContext),
      key: ObjectKey(_commands),
    );
    final value = await modal.show<CommandReturn>(context);
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

  @override
  void initState() {
    super.initState();
    // Open SelectModal after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showCommandList();
    });
  }

  Future<void> _showCommandList() async {
    if (!mounted) return;

    await SelectModal.open<Command>(
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

    // If we get here and the modal was closed without pushing a page, close the parent modal
    if (mounted && _navigationStack.isEmpty) {
      Modal.pop<CommandReturn>(context, const Value(CommandSkipped()));
    }
  }

  Future<bool> _handleCommandSelection(
    BuildContext modalContext,
    Command command,
    String searchText,
  ) async {
    await _executeCommand(command, modalContext);

    // Return true to close SelectModal if we're not showing a nested page
    // Return false to keep it open if there was an error
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

      // Close all modals and navigate if needed
      Modal.popAll(modalContext);
      if (modalContext.mounted && result is CommandRoute) {
        final routeContext = widget.rootContext.mounted
            ? widget.rootContext
            : modalContext;
        result.go(routeContext);
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

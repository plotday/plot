import 'package:flutter/widgets.dart';

import 'package:plot/command/command.dart';
import 'list_tile.dart';
import 'text_field.dart';
import 'dialog.dart';
import 'button.dart';
import 'theme.dart';
import 'logging.dart';

/// Controller for managing command selection state
class CommandSelectionController extends ChangeNotifier {
  int _selectedIndex = 0;

  /// Current selected index
  int get selectedIndex => _selectedIndex;

  /// Set the selected index and notify listeners
  set selectedIndex(int value) {
    if (_selectedIndex != value) {
      _selectedIndex = value;
      notifyListeners();
    }
  }

  /// Select the next command
  void selectNext(int itemCount) {
    if (itemCount > 0) {
      selectedIndex = (selectedIndex + 1) % itemCount;
    }
  }

  /// Select the previous command
  void selectPrevious(int itemCount) {
    if (itemCount > 0) {
      selectedIndex = (selectedIndex - 1 + itemCount) % itemCount;
    }
  }

  /// Reset selection to the first item
  void reset() {
    selectedIndex = 0;
  }
}

class CommandBar<T> extends StatefulWidget {
  static Future<Value<T>> show<T>(
    BuildContext context,
    Commands<T> commands, {
    Command? Function(String promptValue)? secondaryCommand,
    CommandSelectionController? controller,
  }) => Dialog.show<T>(
    context: context,
    builder:
        (context) => CommandBar<T>(
          commands,
          secondaryCommand: secondaryCommand,
          controller: controller,
        ),
  );

  final Commands<T> commands;
  final Command? Function(String promptValue)? secondaryCommand;
  final CommandSelectionController? controller;

  const CommandBar(
    this.commands, {
    this.secondaryCommand,
    this.controller,
    super.key,
  });

  @override
  CommandBarState<T> createState() => CommandBarState();
}

class CommandBarState<T> extends State<CommandBar<T>> {
  final TextEditingController _controller = TextEditingController();
  late final CommandSelectionController _selectionController;
  List<StaticCommandGroup> _filteredCommandGroups = [];
  late Commands<T> commands = widget.commands;
  Widget? _child;
  String? _error;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();

    // Initialize selection controller (use provided or create default)
    _selectionController = widget.controller ?? CommandSelectionController();

    _initCommands();
    _controller.addListener(_initCommands);

    // Listen for selection changes to update UI
    _selectionController.addListener(() {
      if (!_isDisposed) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    _controller.removeListener(_initCommands);
    // Only dispose the selection controller if we created it
    if (widget.controller == null) {
      _selectionController.dispose();
    }
    super.dispose();
  }

  void _initCommands() async {
    try {
      setState(() {
        _error = null;
      });
      final searchText = _controller.text;
      final commandsList = await commands.list(search: searchText);

      if (_isDisposed) return;

      setState(() {
        if (commandsList.isEmpty) {
          _error = 'No matches';
        }
        _filteredCommandGroups = commandsList;
        // Reset selection when commands change
        _selectionController.reset();
      });
    } catch (e) {
      print('Error initializing commands: $e');
      if (!_isDisposed) {
        setState(() {
          _error = 'Search failed.';
        });
      }
    }
  }

  int _allCommandsCount() {
    return _filteredCommandGroups.fold(
      0,
      (total, group) => total + group.commands.length,
    );
  }

  Future<CommandReturn?> _executeCommand(Command command) async {
    try {
      final result = await command.run(context);

      if (result is CommandCommands<T>) {
        commands = result.commands;
        _initCommands();
      } else if (result is CommandPage) {
        setState(() => _child = result.child);
      } else if (result is CommandValue<T> && mounted) {
        Navigator.of(context).pop(Value(result.value));
      } else if (result is CommandValue<T?> &&
          result.value != null &&
          mounted) {
        Navigator.of(context).pop(Value(result.value!));
      }
    } catch (e, stackTrace) {
      log.warning('Error executing command', e, stackTrace);
    }
    return null;
  }

  /// Execute the currently selected command
  void _executeSelectedCommand() {
    final selectedIndex = _selectionController.selectedIndex;
    if (selectedIndex >= 0 && selectedIndex < _allCommandsCount()) {
      final command = _getCommandAtIndex(selectedIndex);
      _executeCommand(command);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_child != null) {
      return _child!;
    }

    Widget? errorBox;
    if (_error != null) {
      errorBox = Container(
        padding: const EdgeInsets.all(8),
        child: Text(_error!),
      );
    }

    final secondaryCommand = widget.secondaryCommand?.call(_controller.text);
    final totalCommandCount = _allCommandsCount();

    return Dialog(
      padding: const EdgeInsets.all(0),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_child != null) _child!,
          if (_child == null) ...[
            EditableArea(
              position: EditableAreaPosition.top,
              padding: false,
              builder:
                  (context, focusNode) => Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: widgetPadding,
                          child: TextField(
                            style: TextFieldStyle.ghost,
                            controller: _controller,
                            autofocus: true,
                            label: widget.commands.prompt,
                            focusNode: focusNode,
                            // onKeyDown: (event) {
                            //   // Handle keyboard navigation
                            //   if (event.isKeyPressed(
                            //     LogicalKeyboardKey.arrowDown,
                            //   )) {
                            //     _selectionController.selectNext(
                            //       totalCommandCount,
                            //     );
                            //     return true;
                            //   } else if (event.isKeyPressed(
                            //     LogicalKeyboardKey.arrowUp,
                            //   )) {
                            //     _selectionController.selectPrevious(
                            //       totalCommandCount,
                            //     );
                            //     return true;
                            //   } else if (event.isKeyPressed(
                            //     LogicalKeyboardKey.enter,
                            //   )) {
                            //     _executeSelectedCommand();
                            //     return true;
                            //   }
                            //   return false;
                            // },
                          ),
                        ),
                      ),
                      if (secondaryCommand != null)
                        Button.icon(
                          CommandWrapper(
                            secondaryCommand,
                            run: (_, __) => _executeCommand(secondaryCommand),
                          ),
                        ),
                    ],
                  ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: 400),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: totalCommandCount,
                itemBuilder: (context, index) {
                  final group = _getGroupAtIndex(index);
                  final command = _getCommandAtIndex(index);
                  final body = command.buildBody(context);
                  Widget? header;
                  if (index == 0 || group != _getGroupAtIndex(index - 1)) {
                    header = Text(group.title);
                  }
                  return Column(
                    children: [
                      if (header != null) header,
                      ListTile(
                        command: command,
                        body: body,
                        selected: _selectionController.selectedIndex == index,
                      ),
                    ],
                  );
                },
              ),
            ),
            if (errorBox != null) errorBox,
          ],
        ],
      ),
    );
  }

  StaticCommandGroup _getGroupAtIndex(int index) {
    int currentIndex = 0;
    for (final group in _filteredCommandGroups) {
      if (index < currentIndex + group.commands.length) {
        return group;
      }
      currentIndex += group.commands.length;
    }
    throw Exception('Command index out of range');
  }

  Command _getCommandAtIndex(int index) {
    int currentIndex = 0;
    for (final group in _filteredCommandGroups) {
      for (final command in group.commands) {
        if (currentIndex == index) {
          return CommandWrapper(
            command,
            run: (_, __) => _executeCommand(command),
          );
        }
        currentIndex++;
      }
    }
    throw Exception('Command index out of range');
  }
}

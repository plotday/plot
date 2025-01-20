import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:plot/command/command.dart';
import 'text_field.dart';
import 'dialog.dart';

class CommandBar extends StatefulWidget {
  static Future<T?> show<T>(BuildContext context, Commands commands) =>
      Dialog.show<T>(
        context: context,
        builder: (context) => CommandBar(commands),
      );

  final Commands commands;

  const CommandBar(this.commands, {super.key});

  @override
  CommandBarState createState() => CommandBarState();
}

class CommandBarState extends State<CommandBar> {
  final TextEditingController _controller = TextEditingController();
  List<CommandGroup> _filteredCommandGroups = [];
  int _focusedCommandIndex = 0;
  late Commands commands = widget.commands;
  Widget? _child;
  String? _error;

  @override
  void initState() {
    super.initState();

    _initCommands();

    _controller.addListener(_initCommands);
  }

  void _initCommands() async {
    try {
      setState(() {
        _filteredCommandGroups = [];
        _error = null;
      });
      final searchText = _controller.text;
      final commandsList = await commands.list(search: searchText);
      setState(() {
        _filteredCommandGroups = commandsList;
        _focusedCommandIndex = 0;
      });
    } catch (e) {
      print('Error initializing commands: $e');
      setState(() {
        _error = 'Search failed.';
      });
    }
  }

  void _onKeyAction(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() {
          _focusedCommandIndex =
              (_focusedCommandIndex + 1) % _allCommandsCount();
        });
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() {
          _focusedCommandIndex =
              (_focusedCommandIndex - 1 + _allCommandsCount()) %
                  _allCommandsCount();
        });
      } else if (event.logicalKey == LogicalKeyboardKey.enter) {
        _executeCommand();
      }
    }
  }

  int _allCommandsCount() {
    return _filteredCommandGroups.fold(
        0, (total, group) => total + group.commands.length);
  }

  Command _getFocusedCommand() {
    int index = 0;
    for (var group in _filteredCommandGroups) {
      if (_focusedCommandIndex < index + group.commands.length) {
        return group.commands[_focusedCommandIndex - index];
      }
      index += group.commands.length;
    }
    throw Exception('Focused command index out of bounds');
  }

  void _executeCommand() async {
    try {
      final focusedCommand = _getFocusedCommand();
      final result = await focusedCommand.run(context);

      if (result is CommandCommands) {
        commands = result.commands;
        _initCommands();
      } else if (result is CommandPage) {
        setState(() => _child = result.child);
      } else if (result is CommandValue && mounted) {
        Navigator.of(context).pop(result.value);
      }
    } catch (e) {
      print('Error executing command: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final heightConstraint = mediaQuery.size.height * 0.8;
    if (_child != null) {
      return Dialog(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: heightConstraint,
            maxWidth: 750,
          ),
          padding: const EdgeInsets.all(16.0),
          child: _child,
        ),
      );
    }
    return KeyboardListener(
      focusNode: FocusNode(),
      onKeyEvent: _onKeyAction,
      child: Dialog(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: heightConstraint,
            maxWidth: 750,
          ),
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null) Text(_error!),
              if (_child != null) _child!,
              if (_child == null) ...[
                TextField(
                  controller: _controller,
                  autofocus: true,
                  label: widget.commands.prompt,
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _allCommandsCount(),
                    itemBuilder: (context, index) {
                      final command = _getCommandAtIndex(index);
                      return command.build(
                        context,
                        selected: index == _focusedCommandIndex,
                        onTap: _executeCommand,
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Command _getCommandAtIndex(int index) {
    int currentIndex = 0;
    for (final group in _filteredCommandGroups) {
      for (final command in group.commands) {
        if (currentIndex == index) return command;
        currentIndex++;
      }
    }
    throw Exception('Command index out of range');
  }
}

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' as material;

import 'package:plot/command/command.dart';

class CommandBar extends StatefulWidget {
  static Future<T?> show<T>(BuildContext context, Commands commands) =>
      material.showDialog<T>(
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

  @override
  void initState() {
    super.initState();

    _initCommands();

    _controller.addListener(_onTextChanged);
  }

  void _initCommands() async {
    final commandsList = await commands.list();
    setState(() {
      _filteredCommandGroups = commandsList;
    });
  }

  void _onTextChanged() async {
    final searchText = _controller.text;

    final commandsList = await commands.list(search: searchText);
    setState(() {
      _filteredCommandGroups = commandsList;
      _focusedCommandIndex = 0;
    });
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
    final heightConstraint = mediaQuery.size.height * 0.5;
    return KeyboardListener(
      focusNode: FocusNode(),
      onKeyEvent: _onKeyAction,
      child: material.Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              commands.title,
              style: material.Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            material.TextField(
              controller: _controller,
              autofocus: true,
              decoration:
                  const material.InputDecoration(hintText: 'Type your command'),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: Container(
                constraints: BoxConstraints(maxHeight: heightConstraint),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _allCommandsCount(),
                  itemBuilder: (context, index) {
                    final command = _getCommandAtIndex(index);
                    return material.ListTile(
                      leading: command.icon,
                      title: Text(command.title),
                      subtitle: command.subtitle != null
                          ? Text(command.subtitle!)
                          : null,
                      selected: index == _focusedCommandIndex,
                      onTap: _executeCommand,
                    );
                  },
                ),
              ),
            ),
          ],
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

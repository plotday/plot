import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:plot/command/command.dart';
import 'list_tile.dart';
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
  List<StaticCommandGroup> _filteredCommandGroups = [];
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

  int _allCommandsCount() {
    return _filteredCommandGroups.fold(
        0, (total, group) => total + group.commands.length);
  }

  Future<CommandReturn?> _executeCommand(Command command) async {
    try {
      final result = await command.run(context);

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
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_child != null) {
      return Dialog(
        child: _child!,
      );
    }
    return Dialog(
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
                  return ListTile.command(command);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Command _getCommandAtIndex(int index) {
    int currentIndex = 0;
    for (final group in _filteredCommandGroups) {
      for (final command in group.commands) {
        if (currentIndex == index) {
          return CommandWrapper(
            command,
            run: (_) => _executeCommand(command),
          );
        }
        currentIndex++;
      }
    }
    throw Exception('Command index out of range');
  }
}

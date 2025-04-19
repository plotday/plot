import 'package:flutter/widgets.dart';

import 'package:plot/command/command.dart';
import 'list_tile.dart';
import 'text_field.dart';
import 'dialog.dart';
import 'button.dart';
import 'theme.dart';
import 'logging.dart';

class CommandBar<T> extends StatefulWidget {
  static Future<Value<T>> show<T>(
    BuildContext context,
    Commands<T> commands, {
    Command? Function(String promptValue)? secondaryCommand,
  }) =>
      Dialog.show<T>(
        context: context,
        builder: (context) =>
            CommandBar<T>(commands, secondaryCommand: secondaryCommand),
      );

  final Commands<T> commands;
  final Command? Function(String promptValue)? secondaryCommand;

  const CommandBar(this.commands, {this.secondaryCommand, super.key});

  @override
  CommandBarState<T> createState() => CommandBarState();
}

class CommandBarState<T> extends State<CommandBar<T>> {
  final TextEditingController _controller = TextEditingController();
  List<StaticCommandGroup> _filteredCommandGroups = [];
  late Commands<T> commands = widget.commands;
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

  @override
  Widget build(BuildContext context) {
    if (_child != null) {
      return Dialog(child: _child!);
    }
    final secondaryCommand = widget.secondaryCommand?.call(_controller.text);
    return Dialog(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) Text(_error!),
          if (_child != null) _child!,
          if (_child == null) ...[
            EditableArea(
              position: EditableAreaPosition.top,
              padding: false,
              builder: (context, focusNode) => Row(
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
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _allCommandsCount(),
                itemBuilder: (context, index) {
                  final command = _getCommandAtIndex(index);
                  return ListTile(command: command);
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
            run: (_, __) => _executeCommand(command),
          );
        }
        currentIndex++;
      }
    }
    throw Exception('Command index out of range');
  }
}

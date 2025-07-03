import 'package:flutter/widgets.dart';

import 'package:plot/command/command.dart';
import 'package:plot/widget/bidirectional_list.dart';
import 'list_tile.dart';
import 'text_field.dart';
import 'dialog.dart';
import 'button.dart';
import 'theme.dart';
import 'logging.dart';

class CommandBar extends Dialog {
  CommandBar(
    Commands commands, {
    Command? Function(String promptValue)? secondaryCommand,
    super.key,
  }) : super(
         padding: const EdgeInsets.all(0),
         builder: (_) =>
             _CommandBar(commands, secondaryCommand: secondaryCommand),
       );

  Future<CommandReturn> run(BuildContext context) {
    return super
        .show<CommandReturn>(context)
        .then((value) => value.present ? value.value : const CommandSkipped());
  }
}

class _CommandBar extends StatefulWidget {
  const _CommandBar(this.commands, {this.secondaryCommand});

  final Commands commands;
  final Command? Function(String promptValue)? secondaryCommand;

  @override
  CommandBarState createState() => CommandBarState();
}

class CommandBarState extends State<_CommandBar> {
  final TextEditingController _controller = TextEditingController();
  List<StaticCommandGroup> _filteredCommandGroups = [];
  late Commands commands = widget.commands;
  Widget? _child;
  String? _error;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();

    _initCommands();
    _controller.addListener(_initCommands);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _controller.removeListener(_initCommands);
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
        // _selectionController.reset();
      });
    } catch (e, t) {
      log.warning('Error initializing commands', e, t);
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

  Future<CommandReturn> _executeCommand(Command command) async {
    setState(() {
      _error = null;
    });
    try {
      final result = await command.run(context);
      if (!mounted) return const CommandSkipped();
      if (result is CommandSkipped) {
        return result;
      } else if (result is CommandMessage) {
        setState(() {
          _error = result.message;
        });
        return const CommandDone();
      }
      DialogProvider.of(context).popAll(context);
      if (result is CommandRoute) {
        result.go(context);
      }
    } catch (e, stackTrace) {
      log.warning('Error executing command', e, stackTrace);
      setState(() {
        _error = 'Something went wrong';
      });
    }
    return const CommandDone();
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

    return BidirectionalListSelector(
      onActivate: (index) => _executeCommand(_getCommandAtIndex(index)),
      builder: (context, listController) => Shortcuts(
        shortcuts: BidirectionalList.shortcuts,
        child: _child != null
            ? _child!
            : Column(
                children: [
                  EditableArea(
                    position: EditableAreaPosition.top,
                    padding: false,
                    builder: (context, focusNode) => Row(
                      children: [
                        Expanded(
                          child: Padding(
                            padding: widgetPadding,
                            child: TextField(
                              maxLines: 1,
                              style: TextFieldStyle.ghost,
                              controller: _controller,
                              autofocus: true,
                              label: "${widget.commands.prompt}…",
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
                  if (errorBox != null) errorBox,
                  Flexible(
                    child: BidirectionalList(
                      // shrinkWrap: true,
                      controller: listController,
                      count: totalCommandCount,
                      builder: (context, index, selected) {
                        final group = _getGroupAtIndex(index);
                        final command = _getCommandAtIndex(index);
                        final body = command.buildBody(context);
                        Widget? header;
                        if (index == 0 ||
                            group != _getGroupAtIndex(index - 1)) {
                          header = Text(group.title);
                        }
                        return Column(
                          key: ValueKey(index),
                          children: [
                            if (header != null) header,
                            ListTile(
                              command: command,
                              body: body,
                              selected: listController.selected == index,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
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

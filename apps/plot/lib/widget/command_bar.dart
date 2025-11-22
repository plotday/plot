import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/widget/bidirectional_list.dart';
import 'list_tile.dart';
import 'package:plot/style/layout.dart';
import 'text_field.dart';
import 'dialog.dart';
import 'button.dart';
import 'logging.dart';

class CommandBar extends Dialog {
  CommandBar(
    Commands commands, {
    Command? Function(String promptValue)? secondaryCommand,
    required BuildContext rootContext,
  }) : super(
         padding: const EdgeInsets.all(0),
         builder: (_) => _CommandBar(
           commands,
           secondaryCommand: secondaryCommand,
           rootContext: rootContext,
         ),
         key: ObjectKey(commands),
       );

  Future<CommandReturn> run(BuildContext context) {
    return super
        .show<CommandReturn>(context)
        .then((value) => value.present ? value.value : const CommandSkipped());
  }
}

class _CommandBar extends StatefulWidget {
  const _CommandBar(
    this.commands, {
    this.secondaryCommand,
    required this.rootContext,
  });

  final Commands commands;
  final Command? Function(String promptValue)? secondaryCommand;
  final BuildContext rootContext;

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
  int _highlightedIndex = 0; // Track highlighted item for keyboard navigation

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
        // Reset highlight to first item when commands change
        _highlightedIndex = 0;
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

  void _moveHighlight(int offset) {
    setState(() {
      final totalCount = _allCommandsCount();
      if (totalCount == 0) return;

      _highlightedIndex = (_highlightedIndex + offset).clamp(0, totalCount - 1);
    });
  }

  Future<CommandReturn> _executeCommand(Command command) async {
    setState(() {
      _error = null;
    });
    try {
      // Use rootContext which has access to providers
      final result = await command.run(widget.rootContext);
      if (!mounted) return const CommandSkipped();
      if (result is CommandSkipped) {
        return result;
      } else if (result is CommandMessage) {
        if (result.isError) {
          setState(() {
            _error = result.message;
          });
          return const CommandDone();
        } else {
          // TODO: Show success message in a non-intrusive way
        }
      }
      Dialog.popAll(context);
      if (context.mounted && result is CommandRoute) {
        result.go(widget.rootContext);
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
      key: ValueKey(totalCommandCount),
      onActivate: (index) => _executeCommand(_getCommandAtIndex(index)),
      builder: (context, listController) => Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowUp): MoveListSelectionIntent(
            -1,
          ),
          SingleActivator(LogicalKeyboardKey.arrowDown):
              MoveListSelectionIntent(1),
          SingleActivator(LogicalKeyboardKey.enter):
              ActivateListSelectionIntent(),
        },
        child: Actions(
          actions: {
            MoveListSelectionIntent: CallbackAction<MoveListSelectionIntent>(
              onInvoke: (intent) {
                _moveHighlight(intent.offset);
                return KeyEventResult.handled;
              },
            ),
            ActivateListSelectionIntent:
                CallbackAction<ActivateListSelectionIntent>(
                  onInvoke: (intent) {
                    if (_allCommandsCount() > 0) {
                      _executeCommand(_getCommandAtIndex(_highlightedIndex));
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
          },
          child: _child != null
              ? _child!
              : SizedBox.expand(
                  child: Column(
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
                                  run: (_, _) =>
                                      _executeCommand(secondaryCommand),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (errorBox != null) errorBox,
                      Expanded(
                        child: BidirectionalList(
                          // shrinkWrap: true,
                          controller: listController,
                          count: totalCommandCount,
                          builder: (context, index, focusNode) {
                            final group = _getGroupAtIndex(index);
                            final command = _getCommandAtIndex(index);
                            final body = command.buildBody(context);
                            Widget? header;
                            Widget? info;
                            if (group.title != null &&
                                (index == 0 ||
                                    group != _getGroupAtIndex(index - 1))) {
                              header = Padding(
                                padding: widgetPaddingSm,
                                child: Text(
                                  group.title!,

                                  style: TextStyle(
                                    color: context.theme.colors.mutedForeground,
                                    fontSize:
                                        context.theme.typography.sm.fontSize,
                                  ),
                                ),
                              );
                            }
                            // Render info widget if provided
                            if (group.infoBuilder != null) {
                              info = Container(
                                padding: const EdgeInsets.all(0),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: context.theme.colors.border,
                                      width: 1,
                                    ),
                                  ),
                                ),
                                child: group.infoBuilder!(context),
                              );
                            }
                            return Column(
                              key: ValueKey(index),
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (header != null) header,
                                if (info != null) info,
                                ListTile(
                                  command: command,
                                  body: body,
                                  selected: index == _highlightedIndex,
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
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
    throw Exception('Action index out of range');
  }

  Command _getCommandAtIndex(int index) {
    int currentIndex = 0;
    for (final group in _filteredCommandGroups) {
      for (final command in group.commands) {
        if (currentIndex == index) {
          return CommandWrapper(
            command,
            run: (_, _) => _executeCommand(command),
          );
        }
        currentIndex++;
      }
    }
    throw Exception('Action index out of range');
  }
}

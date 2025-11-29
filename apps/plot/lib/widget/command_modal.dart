import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/widget/list_view_selector.dart';
import 'package:plot/analytics/analytics.dart';
import 'package:plot/util/platform.dart';
import 'list_tile.dart';
import 'package:plot/style/layout.dart';
import 'text_field.dart';
import 'modal.dart';
import 'button.dart';
import 'icon.dart';
import 'logging.dart';

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
  CommandModal(
    Commands commands, {
    Command? Function(String promptValue)? secondaryCommand,
    required BuildContext rootContext,
  }) : _commands = commands,
       _secondaryCommand = secondaryCommand,
       _rootContext = rootContext;

  final Commands _commands;
  final Command? Function(String promptValue)? _secondaryCommand;
  final BuildContext _rootContext;

  Future<CommandReturn> run(BuildContext context) async {
    // Modal handles multiPanel logic automatically
    final modal = Modal(
      padding: const EdgeInsets.all(0),
      builder: (_) => _CommandModalContent(
        commands: _commands,
        secondaryCommand: _secondaryCommand,
        rootContext: _rootContext,
      ),
      key: ObjectKey(_commands),
    );
    final value = await modal.show<CommandReturn>(context);
    return value.present ? value.value : const CommandSkipped();
  }
}

class _CommandModalContent extends StatefulWidget {
  const _CommandModalContent({
    required this.commands,
    this.secondaryCommand,
    required this.rootContext,
  });

  final Commands commands;
  final Command? Function(String promptValue)? secondaryCommand;
  final BuildContext rootContext;

  @override
  _CommandModalContentState createState() => _CommandModalContentState();
}

class _CommandModalContentState extends State<_CommandModalContent> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<StaticCommandGroup> _filteredCommandGroups = [];
  late Commands commands = widget.commands;
  final List<Widget Function(BuildContext)> _navigationStack = [];
  String? _error;
  bool _isDisposed = false;
  int _highlightedIndex = 0;

  @override
  void initState() {
    super.initState();
    _initCommands();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _scrollController.dispose();
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

  void _moveHighlight(int offset) {
    setState(() {
      final totalCount = _allCommandsCount();
      if (totalCount == 0) return;

      _highlightedIndex = (_highlightedIndex + offset).clamp(0, totalCount - 1);
    });
  }

  int _allCommandsCount() {
    return _filteredCommandGroups.fold(
      0,
      (total, group) => total + group.commands.length,
    );
  }

  void _pushPage(Widget Function(BuildContext) builder) {
    setState(() {
      _navigationStack.add(builder);
    });
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

  Future<CommandReturn> _executeCommand(Command command) async {
    setState(() {
      _error = null;
    });
    try {
      // Use rootContext if mounted, otherwise fall back to current context
      final commandContext = widget.rootContext.mounted
          ? widget.rootContext
          : context;
      final result = await command.run(commandContext);
      if (!mounted) return const CommandSkipped();
      if (result is CommandSkipped) {
        return result;
      } else if (result is CommandPage) {
        // Push nested page onto navigation stack
        _pushPage(result.builder);
        return const CommandDone();
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
      Modal.popAll(context);
      if (context.mounted && result is CommandRoute) {
        final routeContext = widget.rootContext.mounted
            ? widget.rootContext
            : context;
        result.go(routeContext);
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

    Widget? errorBox;
    if (_error != null) {
      errorBox = Container(
        padding: const EdgeInsets.all(8),
        child: Text(_error!),
      );
    }

    final secondaryCommand = widget.secondaryCommand?.call(_controller.text);
    final totalCommandCount = _allCommandsCount();

    return ListViewSelector(
      key: ValueKey(totalCommandCount),
      onActivate: (index) => _executeCommand(_getCommandAtIndex(index)),
      builder: (context, listController) {
        // Set bounds for the controller
        listController.clamp(0, totalCommandCount - 1);

        return Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowUp):
                MoveListSelectionIntent(-1),
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
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasPhysicalKeyboard())
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
                                onChanged: (_) => _initCommands(),
                              ),
                            ),
                          ),
                          if (secondaryCommand != null)
                            Button.icon(
                              CommandWrapper(
                                secondaryCommand,
                                run: (_, _) => _executeCommand(secondaryCommand),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (errorBox != null) errorBox,
                  Flexible(
                    child: ListView.builder(
                      controller: _scrollController,
                      shrinkWrap: true,
                      itemCount: totalCommandCount,
                      itemBuilder: (context, index) {
                        if (index < 0 || index >= totalCommandCount) {
                          return const SizedBox.shrink();
                        }

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
                                fontSize: context.theme.typography.sm.fontSize,
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

                        return MouseRegion(
                          onEnter: (_) => listController.setHovered(index),
                          onExit: (_) => listController.setHovered(null),
                          child: Column(
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
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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

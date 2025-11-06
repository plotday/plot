import 'package:flutter/widgets.dart' hide Action, Actions;
import 'package:forui/forui.dart';

import 'package:plot/action/action.dart';
import 'package:plot/widget/bidirectional_list.dart';
import 'list_tile.dart';
import 'text_field.dart';
import 'dialog.dart';
import 'button.dart';
import 'theme.dart';
import 'logging.dart';

class ActionBar extends Dialog {
  ActionBar(
    Actions actions, {
    Action? Function(String promptValue)? secondaryAction,
    required BuildContext rootContext,
  }) : super(
         padding: const EdgeInsets.all(0),
         builder: (_) => _ActionBar(
           actions,
           secondaryAction: secondaryAction,
           rootContext: rootContext,
         ),
         key: ObjectKey(actions),
       );

  Future<ActionReturn> run(BuildContext context) {
    return super
        .show<ActionReturn>(context)
        .then((value) => value.present ? value.value : const ActionSkipped());
  }
}

class _ActionBar extends StatefulWidget {
  const _ActionBar(
    this.actions, {
    this.secondaryAction,
    required this.rootContext,
  });

  final Actions actions;
  final Action? Function(String promptValue)? secondaryAction;
  final BuildContext rootContext;

  @override
  ActionBarState createState() => ActionBarState();
}

class ActionBarState extends State<_ActionBar> {
  final TextEditingController _controller = TextEditingController();
  List<StaticActionGroup> _filteredActionGroups = [];
  late Actions actions = widget.actions;
  Widget? _child;
  String? _error;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();

    _initActions();
    _controller.addListener(_initActions);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _controller.removeListener(_initActions);
    super.dispose();
  }

  void _initActions() async {
    try {
      setState(() {
        _error = null;
      });
      final searchText = _controller.text;
      final actionsList = await actions.list(search: searchText);

      if (_isDisposed) return;

      setState(() {
        if (actionsList.isEmpty) {
          _error = 'No matches';
        }
        _filteredActionGroups = actionsList;
        // Reset selection when actions change
        // _selectionController.reset();
      });
    } catch (e, t) {
      log.warning('Error initializing actions', e, t);
      if (!_isDisposed) {
        setState(() {
          _error = 'Search failed.';
        });
      }
    }
  }

  int _allActionsCount() {
    return _filteredActionGroups.fold(
      0,
      (total, group) => total + group.actions.length,
    );
  }

  Future<ActionReturn> _executeAction(Action action) async {
    setState(() {
      _error = null;
    });
    try {
      // Use rootContext which has access to providers
      final result = await action.run(widget.rootContext);
      if (!mounted) return const ActionSkipped();
      if (result is ActionSkipped) {
        return result;
      } else if (result is ActionMessage) {
        if (result.isError) {
          setState(() {
            _error = result.message;
          });
          return const ActionDone();
        } else {
          // TODO: Show success message in a non-intrusive way
        }
      }
      Dialog.popAll(context);
      if (result is ActionRoute) {
        result.go(widget.rootContext);
      }
    } catch (e, stackTrace) {
      log.warning('Error executing action', e, stackTrace);
      setState(() {
        _error = 'Something went wrong';
      });
    }
    return const ActionDone();
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

    final secondaryAction = widget.secondaryAction?.call(_controller.text);
    final totalActionCount = _allActionsCount();

    return BidirectionalListSelector(
      onActivate: (index) => _executeAction(_getActionAtIndex(index)),
      builder: (context, listController) => Shortcuts(
        shortcuts: BidirectionalList.shortcuts,
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
                              label: "${widget.actions.prompt}…",
                              focusNode: focusNode,
                            ),
                          ),
                        ),
                        if (secondaryAction != null)
                          Button.icon(
                            ActionWrapper(
                              secondaryAction,
                              run: (_, _) => _executeAction(secondaryAction),
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
                      count: totalActionCount,
                      builder: (context, index, selected) {
                        final group = _getGroupAtIndex(index);
                        final action = _getActionAtIndex(index);
                        final body = action.buildBody(context);
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
                                fontSize: context.theme.typography.xs.fontSize,
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
                              action: action,
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
      ),
    );
  }

  StaticActionGroup _getGroupAtIndex(int index) {
    int currentIndex = 0;
    for (final group in _filteredActionGroups) {
      if (index < currentIndex + group.actions.length) {
        return group;
      }
      currentIndex += group.actions.length;
    }
    throw Exception('Action index out of range');
  }

  Action _getActionAtIndex(int index) {
    int currentIndex = 0;
    for (final group in _filteredActionGroups) {
      for (final action in group.actions) {
        if (currentIndex == index) {
          return ActionWrapper(action, run: (_, _) => _executeAction(action));
        }
        currentIndex++;
      }
    }
    throw Exception('Action index out of range');
  }
}

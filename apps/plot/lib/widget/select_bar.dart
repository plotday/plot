import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:plot/widget/list_view_selector.dart';
import 'package:plot/command/command.dart';
import 'package:plot/analytics/analytics.dart';
import 'package:plot/style/layout.dart';
import 'list_tile.dart';
import 'text_field.dart';
import 'dialog.dart';
import 'logging.dart';

/// A generic selection bar dialog for selecting items from a list.
///
/// Similar to CommandBar but for item selection instead of action execution.
class SelectBar<T> extends Dialog {
  SelectBar({
    required this.items,
    required this.labelBuilder,
    this.subtitleBuilder,
    this.selectedValue,
    this.prompt = 'Search',
    super.key,
  }) : super(
         padding: const EdgeInsets.all(0),
         builder: (_) => _SelectBar<T>(
           items: items,
           labelBuilder: labelBuilder,
           subtitleBuilder: subtitleBuilder,
           selectedValue: selectedValue,
           prompt: prompt,
         ),
       );

  /// Function to fetch items, optionally filtered by search text.
  final Future<List<T>> Function(String? search) items;

  /// Function to build the display label for an item.
  final String Function(T) labelBuilder;

  /// Optional function to build a subtitle for an item.
  final String Function(T)? subtitleBuilder;

  /// The currently selected value (will be highlighted in the list).
  final T? selectedValue;

  /// The placeholder text for the search input.
  final String prompt;

  /// Show the select bar and return the selected value, or null if cancelled.
  static Future<T?> open<T>(
    BuildContext context, {
    required Future<List<T>> Function(String? search) items,
    required String Function(T) labelBuilder,
    String Function(T)? subtitleBuilder,
    T? selectedValue,
    String prompt = 'Search',
  }) async {
    final result = await SelectBar<T>(
      items: items,
      labelBuilder: labelBuilder,
      subtitleBuilder: subtitleBuilder,
      selectedValue: selectedValue,
      prompt: prompt,
    ).show<T>(context);

    return result.present ? result.value : null;
  }
}

class _SelectBar<T> extends StatefulWidget {
  const _SelectBar({
    required this.items,
    required this.labelBuilder,
    this.subtitleBuilder,
    this.selectedValue,
    required this.prompt,
  });

  final Future<List<T>> Function(String? search) items;
  final String Function(T) labelBuilder;
  final String Function(T)? subtitleBuilder;
  final T? selectedValue;
  final String prompt;

  @override
  _SelectBarState<T> createState() => _SelectBarState<T>();
}

class _SelectBarState<T> extends State<_SelectBar<T>> {
  final TextEditingController _controller = TextEditingController();
  List<T> _filteredItems = [];
  String? _error;
  bool _isDisposed = false;
  int _highlightedIndex = 0;

  @override
  void initState() {
    super.initState();
    _initItems();
    _controller.addListener(_initItems);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _controller.removeListener(_initItems);
    _controller.dispose();
    super.dispose();
  }

  void _initItems() async {
    try {
      setState(() {
        _error = null;
      });
      final searchText = _controller.text.isEmpty ? null : _controller.text;
      final itemsList = await widget.items(searchText);

      if (_isDisposed) return;

      setState(() {
        if (itemsList.isEmpty) {
          _error = 'No matches';
        }
        _filteredItems = itemsList;

        // Find the selected item's index to highlight it
        if (widget.selectedValue != null && _controller.text.isEmpty) {
          final selectedIndex = itemsList.indexWhere((item) {
            return widget.labelBuilder(item) ==
                widget.labelBuilder(widget.selectedValue as T);
          });
          if (selectedIndex >= 0) {
            _highlightedIndex = selectedIndex;
          } else {
            _highlightedIndex = 0;
          }
        } else {
          _highlightedIndex = 0;
        }
      });
    } catch (e, t) {
      log.warning('Error loading items', e, t);
      if (!_isDisposed) {
        setState(() {
          _error = 'Loading failed.';
        });
      }
    }
  }

  void _moveHighlight(int offset) {
    setState(() {
      final totalCount = _filteredItems.length;
      if (totalCount == 0) return;

      _highlightedIndex = (_highlightedIndex + offset).clamp(0, totalCount - 1);
    });
  }

  void _selectItem(T item) {
    Dialog.pop<T>(context, Value(item));
  }

  void _cancel() {
    Dialog.pop<T>(context, Value.absent());
  }

  @override
  Widget build(BuildContext context) {
    Widget? errorBox;
    if (_error != null) {
      errorBox = Container(
        padding: const EdgeInsets.all(8),
        child: Text(_error!),
      );
    }

    final totalCount = _filteredItems.length;

    return ListViewSelector(
      key: ValueKey(totalCount),
      onActivate: (index) {
        if (index >= 0 && index < _filteredItems.length) {
          _selectItem(_filteredItems[index]);
        }
      },
      builder: (context, listController) {
        // Set bounds for the controller
        listController.clamp(0, totalCount - 1);

        return Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowUp):
                MoveListSelectionIntent(-1),
            SingleActivator(LogicalKeyboardKey.arrowDown):
                MoveListSelectionIntent(1),
            SingleActivator(LogicalKeyboardKey.enter):
                ActivateListSelectionIntent(),
            SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
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
                      if (_filteredItems.isNotEmpty) {
                        _selectItem(_filteredItems[_highlightedIndex]);
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                  ),
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (intent) {
                  _cancel();
                  return KeyEventResult.handled;
                },
              ),
            },
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EditableArea(
                    position: EditableAreaPosition.top,
                    padding: false,
                    builder: (context, focusNode) => Padding(
                      padding: widgetPadding,
                      child: TextField(
                        maxLines: 1,
                        style: TextFieldStyle.ghost,
                        controller: _controller,
                        autofocus: true,
                        label: "${widget.prompt}...",
                        focusNode: focusNode,
                      ),
                    ),
                  ),
                  if (errorBox != null) errorBox,
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight - 100,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: totalCount,
                      itemBuilder: (context, index) {
                        if (index < 0 || index >= _filteredItems.length) {
                          return const SizedBox.shrink();
                        }

                        final item = _filteredItems[index];
                        final label = widget.labelBuilder(item);
                        final subtitle = widget.subtitleBuilder?.call(item);

                        // Create a simple action for the ListTile
                        final action = _SelectItemCommand<T>(
                          title: label,
                          subtitle: subtitle,
                          onSelect: () => _selectItem(item),
                        );

                        return MouseRegion(
                          onEnter: (_) => listController.setHovered(index),
                          onExit: (_) => listController.setHovered(null),
                          child: ListTile(
                            command: action,
                            selected: index == _highlightedIndex,
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Simple command for selecting an item in SelectBar
class _SelectItemCommand<T> extends Command {
  _SelectItemCommand({
    required super.title,
    super.subtitle,
    required this.onSelect,
  }) : super(
         eventObject: EventObject.dialog,
         eventAction: EventAction.selected,
       );

  final VoidCallback onSelect;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    onSelect();
    return const CommandDone();
  }
}

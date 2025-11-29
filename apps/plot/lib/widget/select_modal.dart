import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show Value;

import 'package:plot/widget/list_view_selector.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/style/layout.dart';
import 'text_field.dart';
import 'modal.dart';
import 'logging.dart';

/// A generic selection modal for selecting items from a list.
///
/// Similar to CommandModal but for item selection instead of action execution.
class SelectModal<T> extends Modal {
  SelectModal({
    required this.items,
    required this.itemBuilder,
    this.selectedValue,
    this.prompt = 'Search',
    super.key,
  }) : super(
         padding: const EdgeInsets.all(0),
         builder: (_) => _SelectModal<T>(
           items: items,
           itemBuilder: itemBuilder,
           selectedValue: selectedValue,
           prompt: prompt,
         ),
       );

  /// Function to fetch items, optionally filtered by search text.
  /// All filtering should happen in this callback.
  final Future<List<T>> Function(String? search) items;

  /// Function to build the widget for an item.
  final Widget Function(T) itemBuilder;

  /// The currently selected value (will be highlighted in the list).
  final T? selectedValue;

  /// The placeholder text for the search input.
  final String prompt;

  /// Show the select modal and return the selected value wrapped in Value,
  /// or Value.absent() if cancelled.
  static Future<Value<T>> open<T>(
    BuildContext context, {
    required Future<List<T>> Function(String? search) items,
    required Widget Function(T) itemBuilder,
    T? selectedValue,
    String prompt = 'Search',
  }) async {
    final result = await SelectModal<T>(
      items: items,
      itemBuilder: itemBuilder,
      selectedValue: selectedValue,
      prompt: prompt,
    ).show<T>(context);

    return result;
  }
}

class _SelectModal<T> extends StatefulWidget {
  const _SelectModal({
    required this.items,
    required this.itemBuilder,
    this.selectedValue,
    required this.prompt,
  });

  final Future<List<T>> Function(String? search) items;
  final Widget Function(T) itemBuilder;
  final T? selectedValue;
  final String prompt;

  @override
  _SelectModalState<T> createState() => _SelectModalState<T>();
}

class _SelectModalState<T> extends State<_SelectModal<T>> {
  final TextEditingController _controller = TextEditingController();
  List<T> _filteredItems = [];
  String? _error;
  bool _isDisposed = false;
  int _highlightedIndex = 0;

  @override
  void initState() {
    super.initState();
    _initItems();
  }

  @override
  void dispose() {
    _isDisposed = true;
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
        if (widget.selectedValue != null) {
          final selectedIndex = itemsList.indexWhere((item) {
            return item == widget.selectedValue;
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
    Modal.pop<T>(context, Value(item));
  }

  void _cancel() {
    Modal.pop<T>(context, Value.absent());
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
                  if (hasPhysicalKeyboard())
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
                          onChanged: (text) => _initItems(),
                        ),
                      ),
                    ),
                  if (errorBox != null) errorBox,
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: totalCount,
                      itemBuilder: (context, index) {
                        if (index < 0 || index >= _filteredItems.length) {
                          return const SizedBox.shrink();
                        }

                        final item = _filteredItems[index];

                        return MouseRegion(
                          onEnter: (_) => listController.setHovered(index),
                          onExit: (_) => listController.setHovered(null),
                          child: GestureDetector(
                            onTap: () => _selectItem(item),
                            child: Container(
                              decoration: BoxDecoration(
                                color: index == _highlightedIndex
                                    ? const Color(0x10FFFFFF)
                                    : null,
                              ),
                              child: widget.itemBuilder(item),
                            ),
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

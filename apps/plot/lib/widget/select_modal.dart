import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show Value;
import 'package:forui/forui.dart';

import 'package:plot/widget/list_view_selector.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/style/layout.dart';
import 'text_field.dart';
import 'modal.dart';
import 'logging.dart';

/// A group of items to display in a SelectModal.
class SelectGroup<T> {
  SelectGroup({this.title, required this.items, this.infoBuilder, this.hint});

  /// The title of the group (displayed as a header).
  final String? title;

  /// The items in this group.
  final List<T> items;

  /// Optional widget to display below the group header.
  final Widget Function(BuildContext)? infoBuilder;

  /// Optional hint shown on the right side (usally a keyboard shortcut).
  final String? hint;
}

/// A generic selection modal for selecting items from a list.
///
/// Similar to CommandModal but for item selection instead of action execution.
class SelectModal<T> extends Modal {
  SelectModal({
    required this.items,
    required this.itemBuilder,
    this.selectedValue,
    this.prompt = 'Search',
    this.onSelect,
    this.initialItems,
    super.key,
  }) : super(
         padding: const EdgeInsets.all(0),
         builder: (_) => _SelectModal<T>(
           items: items,
           itemBuilder: itemBuilder,
           selectedValue: selectedValue,
           prompt: prompt,
           onSelect: onSelect,
           initialItems: initialItems,
         ),
       );

  /// Function to fetch item groups, optionally filtered by search text.
  /// All filtering should happen in this callback.
  /// Groups with empty items will be automatically skipped.
  final Future<List<SelectGroup<T>>> Function(String? search) items;

  /// Function to build the widget for an item.
  final Widget Function(T) itemBuilder;

  /// The currently selected value (will be highlighted in the list).
  final T? selectedValue;

  /// The placeholder text for the search input.
  final String prompt;

  /// Optional callback when an item is selected.
  /// Receives the context, selected item, and current search text.
  /// Return true to close the modal, false to keep it open.
  final Future<bool> Function(BuildContext context, T item, String searchText)?
  onSelect;

  /// Pre-fetched items for empty search to avoid empty list on first build.
  final List<SelectGroup<T>>? initialItems;

  /// Show the select modal and return the selected value wrapped in Value,
  /// or Value.absent() if cancelled.
  static Future<Value<T>> open<T>(
    BuildContext context, {
    required Future<List<SelectGroup<T>>> Function(String? search) items,
    required Widget Function(T) itemBuilder,
    T? selectedValue,
    String prompt = 'Search',
    Future<bool> Function(BuildContext context, T item, String searchText)?
    onSelect,
  }) async {
    // Pre-fetch items for empty search to avoid empty list on first build
    List<SelectGroup<T>>? initialItems;
    try {
      initialItems = await items(null);
    } catch (e, t) {
      log.warning('Error pre-fetching items', e, t);
      // Continue anyway - the modal will handle the error state
    }

    if (!context.mounted) {
      return Value.absent();
    }

    final result = await SelectModal<T>(
      items: items,
      itemBuilder: itemBuilder,
      selectedValue: selectedValue,
      prompt: prompt,
      onSelect: onSelect,
      initialItems: initialItems,
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
    this.onSelect,
    this.initialItems,
  });

  final Future<List<SelectGroup<T>>> Function(String? search) items;
  final Widget Function(T) itemBuilder;
  final T? selectedValue;
  final String prompt;
  final Future<bool> Function(BuildContext context, T item, String searchText)?
  onSelect;
  final List<SelectGroup<T>>? initialItems;

  @override
  _SelectModalState<T> createState() => _SelectModalState<T>();
}

class _SelectModalState<T> extends State<_SelectModal<T>> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<SelectGroup<T>> _groups = [];
  List<SelectGroup<T>>? _emptySearchCache;
  String? _error;
  bool _isDisposed = false;
  int _highlightedIndex = 0;

  @override
  void initState() {
    super.initState();
    // If initial items are provided, use them immediately to avoid empty list
    if (widget.initialItems != null) {
      _groups = widget.initialItems!
          .where((group) => group.items.isNotEmpty)
          .toList();
      _emptySearchCache = _groups;
      _updateHighlightedIndex();
    } else {
      _initItems();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Updates the highlighted index to match the selected value if present.
  void _updateHighlightedIndex() {
    if (widget.selectedValue != null) {
      int currentIndex = 0;
      bool found = false;

      for (final group in _groups) {
        for (final item in group.items) {
          if (item == widget.selectedValue) {
            _highlightedIndex = currentIndex;
            found = true;
            break;
          }
          currentIndex++;
        }
        if (found) break;
      }

      if (!found) {
        _highlightedIndex = 0;
      }
    } else {
      _highlightedIndex = 0;
    }
  }

  void _initItems() async {
    try {
      setState(() {
        _error = null;
      });
      final searchText = _controller.text.isEmpty ? null : _controller.text;

      // Use cached results for empty search if available
      if (searchText == null && _emptySearchCache != null) {
        setState(() {
          _groups = _emptySearchCache!;
          final totalItems = _groups.fold<int>(
            0,
            (sum, group) => sum + group.items.length,
          );
          if (totalItems == 0) {
            _error = 'No matches';
          }
          _updateHighlightedIndex();
        });
        return;
      }

      final groupsList = await widget.items(searchText);

      if (_isDisposed) return;

      setState(() {
        // Filter out groups with empty items
        _groups = groupsList.where((group) => group.items.isNotEmpty).toList();

        // Cache results for empty search
        if (searchText == null) {
          _emptySearchCache = _groups;
        }

        // Calculate total items across all groups
        final totalItems = _groups.fold<int>(
          0,
          (sum, group) => sum + group.items.length,
        );

        if (totalItems == 0) {
          _error = 'No matches';
        }

        // Update highlighted index to match selected value
        _updateHighlightedIndex();
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

  /// Get the total count of items across all groups.
  int _getTotalItemCount() {
    return _groups.fold<int>(0, (sum, group) => sum + group.items.length);
  }

  /// Get the group that contains the item at the given flattened index.
  /// Returns null if index is out of bounds.
  SelectGroup<T>? _getGroupAtIndex(int index) {
    if (index < 0) return null;

    int currentIndex = 0;
    for (final group in _groups) {
      if (index < currentIndex + group.items.length) {
        return group;
      }
      currentIndex += group.items.length;
    }
    return null;
  }

  /// Get the item at the given flattened index (assumes index is valid).
  /// This method should only be called after validating the index is in bounds.
  T _getItemAtIndexUnsafe(int index) {
    int currentIndex = 0;
    for (final group in _groups) {
      if (index < currentIndex + group.items.length) {
        return group.items[index - currentIndex];
      }
      currentIndex += group.items.length;
    }
    throw StateError('Index $index out of bounds');
  }

  void _moveHighlight(int offset) {
    setState(() {
      final totalCount = _getTotalItemCount();
      if (totalCount == 0) return;

      _highlightedIndex = (_highlightedIndex + offset).clamp(0, totalCount - 1);
    });
    _scrollToIndex(_highlightedIndex);
  }

  /// Scrolls to ensure the item at the given index is visible.
  /// Only scrolls if the item is outside or near the viewport edges.
  /// When scrolling down, ensures the next item is also visible for better UX.
  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      const estimatedItemHeight = 50.0;

      // Special case: scroll to top for first item to show headers/info
      if (index == 0) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        return;
      }

      final estimatedOffset = index * estimatedItemHeight;
      final viewportHeight = _scrollController.position.viewportDimension;
      final currentScroll = _scrollController.offset;
      final maxScroll = _scrollController.position.maxScrollExtent;

      // Check if item is above visible area
      if (estimatedOffset < currentScroll) {
        _scrollController.animateTo(
          estimatedOffset,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
      // Check if item (+ next item for look-ahead) is below visible area
      else if (estimatedOffset + (estimatedItemHeight * 2) >
          currentScroll + viewportHeight) {
        // Scroll to show current item + next item
        final targetScroll =
            (estimatedOffset + (estimatedItemHeight * 2) - viewportHeight)
                .clamp(0.0, maxScroll);
        _scrollController.animateTo(
          targetScroll,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
      // Item is already visible, don't scroll
    });
  }

  Future<void> _selectItem(T item) async {
    if (widget.onSelect != null) {
      final shouldClose = await widget.onSelect!(
        context,
        item,
        _controller.text,
      );
      if (!shouldClose) {
        return;
      }
    }
    if (mounted) {
      Modal.pop<T>(context, Value(item));
    }
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

    final totalCount = _getTotalItemCount();

    return ListViewSelector(
      scrollController: _scrollController,
      estimatedItemHeight: 50.0,
      onActivate: (index) {
        if (index >= 0 && index < totalCount) {
          _selectItem(_getItemAtIndexUnsafe(index));
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
                      final totalItems = _getTotalItemCount();
                      if (totalItems > 0 &&
                          _highlightedIndex >= 0 &&
                          _highlightedIndex < totalItems) {
                        _selectItem(_getItemAtIndexUnsafe(_highlightedIndex));
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
                      padding: true,
                      autofocus: true,
                      builder: (context, focusNode) => TextField(
                        maxLines: 1,
                        style: TextFieldStyle.ghost,
                        controller: _controller,
                        autofocus: true,
                        label: "${widget.prompt}...",
                        focusNode: focusNode,
                        onChanged: (text) => _initItems(),
                      ),
                    ),
                  if (errorBox != null) errorBox,
                  Flexible(
                    child: ListView.builder(
                      controller: _scrollController,
                      shrinkWrap: true,
                      itemCount: totalCount,
                      itemBuilder: (context, index) {
                        // Check bounds first (protects against out-of-range access)
                        if (index < 0 || index >= totalCount) {
                          return const SizedBox.shrink();
                        }

                        final group = _getGroupAtIndex(index);
                        // Safety check (should never happen if bounds are correct)
                        if (group == null) {
                          return const SizedBox.shrink();
                        }

                        // Get item (safe to use after bounds check)
                        final item = _getItemAtIndexUnsafe(index);

                        // Check if we need to show a group header
                        Widget? header;
                        Widget? info;
                        if (index == 0 ||
                            group != _getGroupAtIndex(index - 1)) {
                          // Show group header if it has a title
                          if (group.title != null) {
                            // Check if this group has a shortcut (metadata will be ShortcutActivator)
                            header = Padding(
                              padding: widgetPaddingSm,
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      group.title!,
                                      style: TextStyle(
                                        color: context
                                            .theme
                                            .colors
                                            .mutedForeground,
                                        fontSize: context
                                            .theme
                                            .typography
                                            .sm
                                            .fontSize,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  // Show shortcut if present
                                  if (group.hint != null &&
                                      hasPhysicalKeyboard())
                                    Text(
                                      group.hint!,
                                      style: TextStyle(
                                        color: context
                                            .theme
                                            .colors
                                            .mutedForeground,
                                        fontSize: context
                                            .theme
                                            .typography
                                            .xs
                                            .fontSize,
                                      ),
                                    ),
                                ],
                              ),
                            );
                          }

                          // Show group info if it has an infoBuilder
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
                        }

                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (header != null) header,
                            if (info != null) info,
                            MouseRegion(
                              onEnter: (_) => listController.setHovered(index),
                              onExit: (_) => listController.setHovered(null),
                              child: GestureDetector(
                                onTap: () => _selectItem(item),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: (index == _highlightedIndex && hasPhysicalKeyboard())
                                        ? context.theme.colors.secondary
                                        : null,
                                  ),
                                  child: widget.itemBuilder(item),
                                ),
                              ),
                            ),
                          ],
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

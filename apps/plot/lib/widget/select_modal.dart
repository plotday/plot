import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show Value;
import 'package:forui/forui.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/list_view_selector.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/style/spacing.dart';
import 'icon.dart';
import 'list_tile.dart';
import 'text_field.dart';
import 'modal.dart';
import 'spinner.dart';
import 'logging.dart';
import 'toast.dart';

/// A group of items to display in a SelectModal.
class SelectGroup<T> {
  SelectGroup({
    this.title,
    required this.items,
    this.infoBuilder,
    this.hint,
    this.onActivate,
  });

  /// The title of the group (displayed as a header).
  final String? title;

  /// The items in this group.
  final List<T> items;

  /// Optional widget to display below the group header.
  final Widget? Function(BuildContext)? infoBuilder;

  /// Optional hint shown on the right side (usally a keyboard shortcut).
  final String? hint;

  /// Called when an info-only group row is activated (Enter key or tap).
  final void Function(BuildContext)? onActivate;
}

/// A generic selection modal for selecting items from a list.
///
/// Similar to CommandModal but for item selection instead of action execution.
class SelectModal<T> extends Modal {
  SelectModal({
    required this.items,
    required this.itemBuilder,
    this.selectedValue,
    this.title,
    this.prompt,
    this.subtitle,
    this.onSelect,
    this.initialItems,
    this.emptyMessage,
    this.onRefreshNeeded,
    this.showFilter,
    this.onAdd,
    this.filter,
    super.key,
  }) : super(
         padding: const EdgeInsets.all(0),
         builder: (_) => _SelectModal<T>(
           items: items,
           itemBuilder: itemBuilder,
           selectedValue: selectedValue,
           title: title,
           prompt: prompt,
           subtitle: subtitle,
           onSelect: onSelect,
           initialItems: initialItems,
           emptyMessage: emptyMessage,
           onRefreshNeeded: onRefreshNeeded,
           showFilter: showFilter,
           onAdd: onAdd,
           filter: filter,
         ),
       );

  /// Function to fetch item groups, optionally filtered by search text.
  /// All filtering should happen in this callback.
  /// Groups with empty items will be automatically skipped.
  final Future<List<SelectGroup<T>>> Function(String? search) items;

  /// Function to build the widget for an item.
  final Widget Function(T, bool isLoading) itemBuilder;

  /// The currently selected value (will be highlighted in the list).
  final T? selectedValue;

  /// Optional title rendered on the top row (same row as the back button when
  /// nested). Useful when the modal is a confirmation or dialog whose primary
  /// content is a question rather than a list of searchable items.
  final String? title;

  /// The placeholder text for the search input.
  /// When null, displays a search icon with "Search..." placeholder.
  final String? prompt;

  /// Optional subtitle displayed below the search area and above the list.
  final String? subtitle;

  /// Optional callback when an item is selected.
  /// Receives the context, selected item, and current search text.
  /// Return true to close the modal, false to keep it open.
  final Future<bool> Function(BuildContext context, T item, String searchText)?
  onSelect;

  /// Pre-fetched items for empty search to avoid empty list on first build.
  final List<SelectGroup<T>>? initialItems;

  /// Custom message to show when no items match the search.
  /// Defaults to 'No matches' if not provided.
  final String? emptyMessage;

  /// Optional callback to receive a refresh function that can be called
  /// to reload the items while keeping the modal open.
  final void Function(Future<void> Function() refresh)? onRefreshNeeded;

  /// Controls whether the filter/search field is shown.
  /// `null` = default behavior (shown when physical keyboard is present),
  /// `true` = always show, `false` = never show.
  final bool? showFilter;

  /// Optional callback to create a new item inline.
  /// When provided, a "+" button is shown next to the search field.
  /// If the callback returns a non-null value, the modal closes with that value selected.
  final Future<T?> Function(BuildContext context)? onAdd;

  /// Optional predicate for client-side filtering. When provided, after the
  /// initial empty-search fetch populates the cache, subsequent keystrokes
  /// filter the cached items locally (case-insensitive `search` is supplied
  /// pre-lowercased and trimmed) instead of re-running [items]. The fetch is
  /// only re-issued when the search text is cleared.
  final bool Function(T item, String search)? filter;

  /// Show the select modal and return the selected value wrapped in Value,
  /// or Value.absent() if cancelled.
  static Future<Value<T>> open<T>(
    BuildContext context, {
    required Future<List<SelectGroup<T>>> Function(String? search) items,
    required Widget Function(T, bool isLoading) itemBuilder,
    T? selectedValue,
    String? title,
    String? prompt,
    String? subtitle,
    Future<bool> Function(BuildContext context, T item, String searchText)?
    onSelect,
    String? emptyMessage,
    void Function(Future<void> Function() refresh)? onRefreshNeeded,
    bool? showFilter,
    Future<T?> Function(BuildContext context)? onAdd,
    bool Function(T item, String search)? filter,
  }) async {
    // Open the modal immediately; items are fetched asynchronously so the
    // modal appears instantly and a spinner is shown below the list while
    // the first results load.
    final result = await SelectModal<T>(
      items: items,
      itemBuilder: itemBuilder,
      selectedValue: selectedValue,
      title: title,
      prompt: prompt,
      subtitle: subtitle,
      onSelect: onSelect,
      emptyMessage: emptyMessage,
      onRefreshNeeded: onRefreshNeeded,
      showFilter: showFilter,
      onAdd: onAdd,
      filter: filter,
    ).show<T>(context);

    return result;
  }
}

class _SelectModal<T> extends StatefulWidget {
  const _SelectModal({
    required this.items,
    required this.itemBuilder,
    this.selectedValue,
    this.title,
    this.prompt,
    this.subtitle,
    this.onSelect,
    this.initialItems,
    this.emptyMessage,
    this.onRefreshNeeded,
    this.showFilter,
    this.onAdd,
    this.filter,
  });

  final Future<List<SelectGroup<T>>> Function(String? search) items;
  final Widget Function(T, bool isLoading) itemBuilder;
  final T? selectedValue;
  final String? title;
  final String? prompt;
  final String? subtitle;
  final Future<bool> Function(BuildContext context, T item, String searchText)?
  onSelect;
  final List<SelectGroup<T>>? initialItems;
  final String? emptyMessage;
  final void Function(Future<void> Function() refresh)? onRefreshNeeded;
  final bool? showFilter;
  final Future<T?> Function(BuildContext context)? onAdd;
  final bool Function(T item, String search)? filter;

  @override
  _SelectModalState<T> createState() => _SelectModalState<T>();
}

class _SelectModalState<T> extends State<_SelectModal<T>> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _listFocusNode = FocusNode(debugLabel: 'SelectModal-list');
  List<SelectGroup<T>> _groups = [];
  List<SelectGroup<T>>? _emptySearchCache;
  String? _error;
  bool _isDisposed = false;
  bool _isLoading = false;
  int _requestId = 0; // For canceling stale requests
  int _highlightedIndex = 0;
  bool _isRefreshing = false;
  bool _mouseHasMoved = false;
  bool _enterHandled =
      false; // Prevents double-fire between Shortcuts and onSubmit
  int? _loadingIndex;
  Timer? _spinnerDelay;
  Future<void>? _lastFetch;
  // Trimmed search text whose results are currently displayed. Used to flush
  // any in-flight fetch on Enter so we activate against fresh results.
  String _appliedSearch = '';

  static const _spinnerDelayDuration = Duration(milliseconds: 150);

  @override
  void initState() {
    super.initState();

    // Expose refresh capability to parent
    widget.onRefreshNeeded?.call(() => _refreshItems());

    // If initial items are provided, use them immediately to avoid empty list
    if (widget.initialItems != null) {
      _groups = widget.initialItems!
          .where((group) => group.items.isNotEmpty || group.infoBuilder != null)
          .toList();
      _emptySearchCache = _groups;
      _appliedSearch = '';
      final totalItems = _groups.fold<int>(
        0,
        (sum, group) => sum + group.items.length,
      );
      final hasInfoOnly = _groups.any(
        (g) => g.items.isEmpty && g.infoBuilder != null,
      );
      if (totalItems == 0 && !hasInfoOnly) {
        _error = widget.emptyMessage ?? 'No matches';
      }
      _updateHighlightedIndex();
      _scrollToHighlighted();
    } else {
      _initItems();
    }
  }

  /// Refresh items while preserving search text and highlighted index
  Future<void> _refreshItems() async {
    // Clear cache to force re-fetch on refresh
    _emptySearchCache = null;
    _isRefreshing = true;
    await _runFetch();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _spinnerDelay?.cancel();
    _listFocusNode.dispose();
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Scrolls to the highlighted index after a frame so the ListView is laid out.
  void _scrollToHighlighted() {
    if (_highlightedIndex > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isDisposed) _scrollToIndex(_highlightedIndex);
      });
    }
  }

  /// Updates the highlighted index to match the selected value if present.
  void _updateHighlightedIndex({bool preserveOnRefresh = false}) {
    if (widget.selectedValue != null) {
      int currentIndex = 0;
      bool found = false;

      for (final group in _groups) {
        // Account for info-only group slot
        if (group.items.isEmpty && group.infoBuilder != null) {
          currentIndex++;
          continue;
        }
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
    } else if (preserveOnRefresh) {
      // Clamp to valid range but don't reset to 0
      final totalDisplay = _getTotalDisplayCount();
      if (totalDisplay > 0) {
        _highlightedIndex = _highlightedIndex.clamp(0, totalDisplay - 1);
      } else {
        _highlightedIndex = 0;
      }
    } else {
      _highlightedIndex = 0;
    }
  }

  void _initItems() {
    final trimmedText = _controller.text.trim();

    // Local-filter fast path: if the caller provided `filter` and the empty
    // search has populated the cache, filter in-memory and skip the data
    // source entirely. Empty search falls through so the cache hit path in
    // _fetchItems re-uses the cached groups synchronously.
    if (trimmedText.isNotEmpty &&
        widget.filter != null &&
        _emptySearchCache != null) {
      _applyLocalFilter(trimmedText);
      return;
    }

    _runFetch();
  }

  /// Kicks off a fetch and stores its Future so [_flushPendingSearch] can
  /// await the in-flight request before Enter activates an item.
  Future<void> _runFetch() {
    return _lastFetch = _fetchItems();
  }

  /// Awaits any in-flight fetch and, if the search text moved past it
  /// (user typed more, or the cache was bypassed), kicks a fresh fetch
  /// before returning. Ensures Enter acts on results that match the
  /// fully-typed text.
  Future<void> _flushPendingSearch() async {
    while (_lastFetch != null) {
      final fut = _lastFetch;
      await fut;
      if (_isDisposed) return;
      if (identical(fut, _lastFetch)) break;
      // A newer fetch was kicked off while we awaited — settle it too.
    }
    if (_isDisposed) return;
    final pending = _controller.text.trim();
    if (pending == _appliedSearch) return;
    if (pending.isNotEmpty &&
        widget.filter != null &&
        _emptySearchCache != null) {
      _applyLocalFilter(pending);
      return;
    }
    await _runFetch();
  }

  void _applyLocalFilter(String search) {
    // Local filtering supersedes any in-flight fetch.
    _spinnerDelay?.cancel();
    ++_requestId;

    final lower = search.toLowerCase();
    final filtered = _emptySearchCache!
        .map(
          (g) => SelectGroup<T>(
            title: g.title,
            items: g.items.where((it) => widget.filter!(it, lower)).toList(),
            infoBuilder: g.infoBuilder,
            hint: g.hint,
            onActivate: g.onActivate,
          ),
        )
        .where((g) {
          if (g.items.isNotEmpty) return true;
          if (g.infoBuilder == null) return false;
          return g.infoBuilder!(context) != null;
        })
        .toList();

    setState(() {
      _isLoading = false;
      _error = null;
      _groups = filtered;
      _appliedSearch = search;
      final totalItems = _groups.fold<int>(
        0,
        (sum, group) => sum + group.items.length,
      );
      final hasInfoOnly = _groups.any(
        (g) => g.items.isEmpty && g.infoBuilder != null,
      );
      if (totalItems == 0 && !hasInfoOnly) {
        _error = widget.emptyMessage ?? 'No matches';
      }
      _updateHighlightedIndex();
    });
  }

  Future<void> _fetchItems() async {
    final refreshing = _isRefreshing;
    _isRefreshing = false;
    try {
      // Trim whitespace and treat empty trimmed string as null
      final trimmedText = _controller.text.trim();
      final searchText = trimmedText.isEmpty ? null : trimmedText;

      // Use cached results for empty search if available (instant, no spinner)
      if (searchText == null && _emptySearchCache != null) {
        _spinnerDelay?.cancel();
        setState(() {
          _error = null;
          _isLoading = false;
          _groups = _emptySearchCache!;
          _appliedSearch = '';
          final totalItems = _groups.fold<int>(
            0,
            (sum, group) => sum + group.items.length,
          );
          final hasInfoOnly = _groups.any(
            (g) => g.items.isEmpty && g.infoBuilder != null,
          );
          if (totalItems == 0 && !hasInfoOnly) {
            _error = widget.emptyMessage ?? 'No matches';
          }
          _updateHighlightedIndex(preserveOnRefresh: refreshing);
        });
        return;
      }

      // Only show the spinner on a cold load (no existing results to display).
      // Once we have results, every keystroke just keeps showing the prior list
      // until the new one arrives — no flicker, no per-keystroke spinner. The
      // spinner is also deferred so fast cold loads don't flash.
      if (_groups.isEmpty && _error == null) {
        _spinnerDelay?.cancel();
        _spinnerDelay = Timer(_spinnerDelayDuration, () {
          if (_isDisposed) return;
          setState(() => _isLoading = true);
        });
      }

      final currentRequestId = ++_requestId;

      final groupsList = await widget.items(searchText);

      if (_isDisposed) return;

      // Discard stale results
      if (currentRequestId != _requestId) return;

      _spinnerDelay?.cancel();

      setState(() {
        _error = null;
        _isLoading = false;
        // Filter out groups with no items and no visible info content
        _groups = groupsList.where((group) {
          if (group.items.isNotEmpty) return true;
          if (group.infoBuilder == null) return false;
          // Exclude info-only groups whose infoBuilder returns null
          // (e.g. TagRow with no matching tags during search)
          return group.infoBuilder!(context) != null;
        }).toList();

        // Cache results for empty search
        if (searchText == null) {
          _emptySearchCache = _groups;
        }

        _appliedSearch = trimmedText;

        // Calculate total items across all groups
        final totalItems = _groups.fold<int>(
          0,
          (sum, group) => sum + group.items.length,
        );
        final hasInfoOnly = _groups.any(
          (g) => g.items.isEmpty && g.infoBuilder != null,
        );

        if (totalItems == 0 && !hasInfoOnly) {
          _error = widget.emptyMessage ?? 'No matches';
        }

        // Update highlighted index — preserve position on refresh
        _updateHighlightedIndex(preserveOnRefresh: refreshing);
      });
    } catch (e, t) {
      log.warning('Error loading items', e, t);
      // Skip noise from offline / expected API errors; report unexpected
      // failures so we can diagnose modals stuck on "Loading failed."
      if (e is! NetworkException &&
          !(e is ApiException && e.statusCode < 500)) {
        Tracker.captureException(e, t);
      }
      if (!_isDisposed) {
        _spinnerDelay?.cancel();
        setState(() {
          _error = 'Loading failed.';
          _isLoading = false;
        });
      }
    }
  }

  bool get _shouldShowFilter {
    // Always show filter when onAdd is set so the + button is accessible
    if (widget.onAdd != null) return true;
    if (widget.showFilter == false) return false;
    if (widget.showFilter == true) return true;
    // Keep filter visible while user is actively searching so the field
    // doesn't disappear mid-keystroke when a fetch is in flight.
    if (_controller.text.isNotEmpty) return true;
    // Hide filter only during the initial cold load (no items yet) so the
    // spinner is the sole content. On a refresh — e.g. after a nested modal
    // like EditSource pops back — _groups still holds the previous items, so
    // the filter must stay visible to avoid a flash of missing chrome.
    if (_isLoading && _groups.isEmpty) return false;
    // Always show filter when nested so back button shares the row
    if (ModalProvider.of(context).modalStackNotifier.value > 1) return true;
    final totalItems = _groups.fold<int>(0, (sum, g) => sum + g.items.length);
    return totalItems >= 20;
  }

  /// Get the total count of items across all groups.
  /// Get the number of display slots for a group.
  /// Info-only groups (no items, has infoBuilder) get 1 slot.
  int _groupSlotCount(SelectGroup<T> group) {
    if (group.items.isEmpty && group.infoBuilder != null) return 1;
    return group.items.length;
  }

  /// Get the total number of display slots across all groups.
  int _getTotalDisplayCount() {
    return _groups.fold<int>(0, (sum, group) => sum + _groupSlotCount(group));
  }

  /// Get the group that contains the display slot at the given flattened index.
  /// Returns null if index is out of bounds.
  SelectGroup<T>? _getGroupAtIndex(int index) {
    if (index < 0) return null;

    int currentIndex = 0;
    for (final group in _groups) {
      final slots = _groupSlotCount(group);
      if (index < currentIndex + slots) {
        return group;
      }
      currentIndex += slots;
    }
    return null;
  }

  /// Whether the display slot at [index] is an info-only group.
  bool _isInfoOnlySlot(int index) {
    final group = _getGroupAtIndex(index);
    return group != null && group.items.isEmpty && group.infoBuilder != null;
  }

  /// Get the item at the given flattened index (assumes index is valid and
  /// not an info-only slot).
  T _getItemAtIndexUnsafe(int index) {
    int currentIndex = 0;
    for (final group in _groups) {
      final slots = _groupSlotCount(group);
      if (index < currentIndex + slots) {
        return group.items[index - currentIndex];
      }
      currentIndex += slots;
    }
    throw StateError('Index $index out of bounds');
  }

  void _moveHighlight(int offset) {
    setState(() {
      final totalDisplay = _getTotalDisplayCount();
      if (totalDisplay == 0) return;

      _highlightedIndex = (_highlightedIndex + offset).clamp(
        0,
        totalDisplay - 1,
      );
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

  Future<void> _handleEnter() async {
    if (_enterHandled) return;
    _enterHandled = true;
    // Reset flag after microtask to allow future Enter presses
    Future.microtask(() => _enterHandled = false);

    // If the user typed quickly and pressed Enter before the latest fetch
    // returned, settle that fetch (and any successor) so we activate against
    // results that match the fully-typed text.
    if (_controller.text.trim() != _appliedSearch || _lastFetch != null) {
      await _flushPendingSearch();
    }
    if (!mounted) return;

    final totalDisplay = _getTotalDisplayCount();
    if (_highlightedIndex < 0 || _highlightedIndex >= totalDisplay) return;

    if (_isInfoOnlySlot(_highlightedIndex)) {
      final group = _getGroupAtIndex(_highlightedIndex);
      group?.onActivate?.call(context);
    } else {
      _selectItem(_getItemAtIndexUnsafe(_highlightedIndex));
    }
  }

  Future<void> _selectItem(T item) async {
    if (_loadingIndex != null) return; // Already loading
    if (widget.onSelect != null) {
      setState(() => _loadingIndex = _highlightedIndex);
      try {
        final shouldClose = await widget.onSelect!(
          context,
          item,
          _controller.text,
        );
        if (mounted) setState(() => _loadingIndex = null);
        if (!shouldClose) {
          return;
        }
      } catch (e, t) {
        log.warning('onSelect threw', e, t);
        if (mounted) {
          setState(() => _loadingIndex = null);
          context.showToast(message: 'Something went wrong.', isError: true);
        }
        return;
      }
    }
    if (mounted) {
      Modal.pop<T>(context, Value(item));
    }
  }

  Future<void> _handleAdd(BuildContext context) async {
    final result = await widget.onAdd!(context);
    if (result != null && mounted) {
      Modal.pop<T>(this.context, Value(result));
    }
  }

  void _cancel() {
    Modal.pop<T>(context, Value.absent());
  }

  @override
  Widget build(BuildContext context) {
    Widget? loadingIndicator;
    // Only render the spinner during a cold load (no cached results yet).
    // Once the empty-search cache is populated, keystrokes never re-show it.
    if (_isLoading && _emptySearchCache == null) {
      loadingIndicator = Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Spinner(size: 12, color: context.theme.colors.mutedForeground),
        ),
      );
    }

    Widget? errorBox;
    if (_error != null) {
      errorBox = Container(
        padding: const EdgeInsets.all(8),
        child: Text(
          _error!,
          style: TextStyle(
            color: context.theme.colors.mutedForeground,
            fontSize: context.theme.typography.sm.fontSize,
          ),
        ),
      );
    }

    final displayCount = _getTotalDisplayCount();

    return ListViewSelector(
      scrollController: _scrollController,
      estimatedItemHeight: 50.0,
      onActivate: (index) {
        if (index >= 0 && index < displayCount && !_isInfoOnlySlot(index)) {
          _selectItem(_getItemAtIndexUnsafe(index));
        }
      },
      builder: (context, listController) {
        // Set bounds for the controller
        listController.clamp(0, displayCount - 1);

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
                      _handleEnter();
                      return KeyEventResult.handled;
                    },
                  ),
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (intent) {
                  if (_controller.text.isNotEmpty) {
                    _controller.clear();
                    _initItems();
                  } else {
                    _cancel();
                  }
                  return KeyEventResult.handled;
                },
              ),
            },
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_shouldShowFilter)
                    EditableArea(
                      position: EditableAreaPosition.top,
                      padding: false,
                      autofocus: hasPhysicalKeyboard(),
                      builder: (context, focusNode) => Padding(
                        padding: context.theme.spacing.padding,
                        child: ValueListenableBuilder<int>(
                          valueListenable: ModalProvider.of(
                            context,
                          ).modalStackNotifier,
                          builder: (context, stackLength, child) => Row(
                            children: [
                              if (stackLength > 1)
                                FButton.icon(
                                  variant: FButtonVariant.ghost,
                                  onPress: _cancel,
                                  child: Icon(
                                    PlotIcon.left,
                                    size: context.theme.iconSizes.sm,
                                  ),
                                ),
                              Expanded(
                                child: Row(
                                  children: [
                                    if (widget.prompt == null)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 8,
                                        ),
                                        child: Icon(
                                          PlotIcon.search,
                                          size: context.theme.iconSizes.sm,
                                          color: context
                                              .theme
                                              .colors
                                              .mutedForeground,
                                        ),
                                      ),
                                    Expanded(
                                      child: TextField(
                                        maxLines: 1,
                                        style: TextFieldStyle.ghost,
                                        controller: _controller,
                                        autofocus: hasPhysicalKeyboard(),
                                        label: widget.prompt != null
                                            ? "${widget.prompt}..."
                                            : "Search...",
                                        focusNode: focusNode,
                                        onChanged: (text) => _initItems(),
                                        onSubmitted: (_) => _handleEnter(),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (widget.onAdd != null)
                                FButton.icon(
                                  variant: FButtonVariant.ghost,
                                  onPress: () => _handleAdd(context),
                                  child: Icon(
                                    PlotIcon.add,
                                    size: context.theme.iconSizes.sm,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    // When the filter bar is hidden, use a Focus widget to
                    // grab keyboard focus so arrow keys / Enter / Escape work.
                    Builder(
                      builder: (context) {
                        if (hasPhysicalKeyboard() && !_listFocusNode.hasFocus) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted && !_listFocusNode.hasFocus) {
                              _listFocusNode.requestFocus();
                            }
                          });
                        }
                        return Focus(
                          focusNode: _listFocusNode,
                          child: ValueListenableBuilder<int>(
                            valueListenable: ModalProvider.of(
                              context,
                            ).modalStackNotifier,
                            builder: (context, stackLength, _) {
                              final nested = stackLength > 1;
                              if (!nested && widget.title == null) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: context.theme.spacing.paddingSm,
                                child: Row(
                                  children: [
                                    if (nested)
                                      FButton.icon(
                                        variant: FButtonVariant.ghost,
                                        onPress: _cancel,
                                        child: Icon(
                                          PlotIcon.left,
                                          size: context.theme.iconSizes.sm,
                                        ),
                                      ),
                                    if (widget.title != null) ...[
                                      if (nested)
                                        SizedBox(
                                          width: context.theme.spacing.sm,
                                        ),
                                      Expanded(
                                        child: Text(
                                          widget.title!,
                                          style: context.theme.typography.md
                                              .copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
                  if (widget.subtitle != null)
                    Padding(
                      // Left padding = 20 so the subtitle lines up with
                      // ListTile's default content indent (see ListTile's
                      // leading SizedBox width default).
                      padding: EdgeInsets.fromLTRB(
                        20,
                        context.theme.spacing.sm,
                        context.theme.spacing.lg,
                        context.theme.spacing.sm,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.subtitle!,
                          textAlign: TextAlign.start,
                          style: TextStyle(
                            color: context.theme.colors.mutedForeground,
                            fontSize: context.theme.typography.sm.fontSize,
                          ),
                        ),
                      ),
                    ),
                  if (errorBox != null) errorBox,
                  Flexible(
                    child: ListView.builder(
                      controller: _scrollController,
                      shrinkWrap: true,
                      itemCount: displayCount,
                      itemBuilder: (context, index) {
                        final group = _getGroupAtIndex(index);
                        // Safety check (should never happen if bounds are correct)
                        if (group == null) {
                          return const SizedBox.shrink();
                        }

                        final isInfoOnly = _isInfoOnlySlot(index);

                        // Info-only group: render infoBuilder as a
                        // keyboard-navigable, highlightable row.
                        if (isInfoOnly) {
                          final infoWidget = group.infoBuilder!(context);
                          if (infoWidget == null) {
                            return const SizedBox.shrink();
                          }

                          // Show group header for info-only groups,
                          // but skip if the preceding group has the same title
                          Widget? infoHeader;
                          final prevTitle = index > 0
                              ? _getGroupAtIndex(index - 1)?.title
                              : null;
                          if (group.title != null && prevTitle != group.title) {
                            infoHeader = Padding(
                              padding: context.theme.spacing.paddingSm.copyWith(
                                right: context.theme.spacing.xxl,
                              ),
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

                          final isHighlighted = index == _highlightedIndex;
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (infoHeader != null) infoHeader,
                              MouseRegion(
                                onEnter: (_) {
                                  if (!_mouseHasMoved) return;
                                  listController.setHovered(index);
                                  setState(() => _highlightedIndex = index);
                                },
                                onExit: (_) {
                                  if (!_mouseHasMoved) return;
                                  listController.setHovered(null);
                                  setState(() => _highlightedIndex = -1);
                                },
                                onHover: (_) {
                                  if (!_mouseHasMoved) {
                                    setState(() => _mouseHasMoved = true);
                                    listController.setHovered(index);
                                    setState(() => _highlightedIndex = index);
                                  }
                                },
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: group.onActivate != null
                                      ? () => group.onActivate!(context)
                                      : null,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: isHighlighted
                                          ? context.theme.colors.secondary
                                          : null,
                                    ),
                                    child: infoWidget,
                                  ),
                                ),
                              ),
                            ],
                          );
                        }

                        // Regular item in a group with items.
                        final item = _getItemAtIndexUnsafe(index);

                        // Check if we need to show a group header
                        Widget? header;
                        Widget? info;
                        if (index == 0 ||
                            group != _getGroupAtIndex(index - 1)) {
                          // Show group header if it has a title
                          if (group.title != null) {
                            header = Padding(
                              padding: context.theme.spacing.paddingSm.copyWith(
                                right: context.theme.spacing.xxl,
                              ),
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
                            final infoResult = group.infoBuilder!(context);
                            if (infoResult != null) info = infoResult;
                          }
                        }

                        // Build the item widget
                        final isItemLoading = _loadingIndex == index;
                        final itemWidget = widget.itemBuilder(
                          item,
                          isItemLoading,
                        );
                        // Only skip GestureDetector for ListTiles that have a command,
                        // since they handle their own taps and spinner logic. ListTiles
                        // without a command (e.g. priority selection) need the wrapper.
                        final handlesOwnTaps =
                            itemWidget is ListTile &&
                            itemWidget.command != null;
                        final Widget child = handlesOwnTaps
                            ? itemWidget
                            : GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: isItemLoading
                                    ? null
                                    : () => _selectItem(item),
                                child: itemWidget,
                              );

                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (header != null) header,
                            if (info != null) info,
                            MouseRegion(
                              onEnter: (_) {
                                if (!_mouseHasMoved) return;
                                listController.setHovered(index);
                                setState(() => _highlightedIndex = index);
                              },
                              onExit: (_) {
                                if (!_mouseHasMoved) return;
                                listController.setHovered(null);
                                setState(() => _highlightedIndex = -1);
                              },
                              onHover: (_) {
                                if (!_mouseHasMoved) {
                                  setState(() => _mouseHasMoved = true);
                                  listController.setHovered(index);
                                  setState(() => _highlightedIndex = index);
                                }
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: index == _highlightedIndex
                                      ? context.theme.colors.secondary
                                      : null,
                                ),
                                child: child,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  if (loadingIndicator != null) loadingIndicator,
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

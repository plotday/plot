import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show Value;
import 'package:forui/forui.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/list_view_selector.dart';
import 'package:plot/widget/scroll_edge_fade.dart';
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

/// A keyboard-navigable "add a new item" row for a [SelectModal] info-only
/// group. Renders a "+" icon and [label] in the muted action style. Pair it
/// with a [SelectGroup] whose `infoBuilder` returns this and whose `onActivate`
/// creates the item, then pops the modal (or advances the flow). Shared so the
/// inline-create affordance looks identical wherever a picker offers it.
Widget addItemRow(BuildContext context, {required String label}) {
  return Padding(
    padding: EdgeInsets.symmetric(
      horizontal: context.theme.spacing.lg,
      vertical: context.theme.spacing.md,
    ),
    child: Row(
      children: [
        Icon(
          PlotIcon.add,
          size: context.theme.iconSizes.sm,
          color: context.theme.colors.mutedForeground,
        ),
        SizedBox(width: context.theme.spacing.md),
        Text(
          label,
          style: TextStyle(color: context.theme.colors.mutedForeground),
        ),
      ],
    ),
  );
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
    this.subtitleWidget,
    this.onSelect,
    this.initialItems,
    this.emptyMessage,
    this.onRefreshNeeded,
    this.onHighlightChanged,
    this.showFilter,
    this.onAdd,
    this.addTooltip,
    this.filter,
    this.clearSearchOnRefresh = false,
    this.gridColumns,
    this.gridCellSize = 36,
    this.gridCellSpacing = 4,
    this.onSecondaryAxis,
    super.key,
    super.constraints,
  }) : super(
         padding: const EdgeInsets.all(0),
         builder: (_) => _SelectModal<T>(
           items: items,
           itemBuilder: itemBuilder,
           selectedValue: selectedValue,
           title: title,
           prompt: prompt,
           subtitle: subtitle,
           subtitleWidget: subtitleWidget,
           onSelect: onSelect,
           initialItems: initialItems,
           emptyMessage: emptyMessage,
           onRefreshNeeded: onRefreshNeeded,
           onHighlightChanged: onHighlightChanged,
           showFilter: showFilter,
           onAdd: onAdd,
           addTooltip: addTooltip,
           filter: filter,
           clearSearchOnRefresh: clearSearchOnRefresh,
           gridColumns: gridColumns,
           gridCellSize: gridCellSize,
           gridCellSpacing: gridCellSpacing,
           onSecondaryAxis: onSecondaryAxis,
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
  /// When null, defaults to a "Search…" placeholder.
  final String? prompt;

  /// Optional subtitle displayed below the search area and above the list.
  final String? subtitle;

  /// Optional rich subtitle rendered in the same slot as [subtitle]. When
  /// provided it takes precedence over [subtitle], letting callers supply
  /// tappable links or other inline widgets instead of plain text.
  final Widget? subtitleWidget;

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

  /// Optional callback fired when the highlighted item changes (mouse hover or
  /// keyboard navigation), settling on a real item slot (never a group header
  /// or info-only row). Fires at most once per distinct highlight. Callers use
  /// it to prefetch data for the row the user is likely to activate next.
  final void Function(T item)? onHighlightChanged;

  /// Controls whether the filter/search field is shown.
  /// `null` = default behavior (shown when physical keyboard is present),
  /// `true` = always show, `false` = never show.
  final bool? showFilter;

  /// Optional callback to create a new item inline.
  /// When provided, a "+" button is shown next to the search field.
  /// If the callback returns a non-null value, the modal closes with that value selected.
  final Future<T?> Function(BuildContext context)? onAdd;

  /// Optional tooltip text shown on hover over the "+" button.
  final String? addTooltip;

  /// Optional predicate for client-side filtering. When provided, after the
  /// initial empty-search fetch populates the cache, subsequent keystrokes
  /// filter the cached items locally (case-insensitive `search` is supplied
  /// pre-lowercased and trimmed) instead of re-running [items]. The fetch is
  /// only re-issued when the search text is cleared.
  final bool Function(T item, String search)? filter;

  /// When true, the search field is cleared every time the list is refreshed
  /// (e.g. after running a command). Multi-select pickers use this so that
  /// toggling a filtered match resets the filter and reveals all selections.
  final bool clearSearchOnRefresh;

  /// When non-null, items render in a grid with this many columns instead of
  /// the default list. Group headers and infoBuilder rows stay full-width.
  /// Arrow up/down move ±[gridColumns] in the flat highlight index; left/right
  /// move ±1.
  final int? gridColumns;

  /// Edge length of each grid cell in logical pixels. Only used when
  /// [gridColumns] is set.
  final double gridCellSize;

  /// Spacing between grid cells in logical pixels. Only used when
  /// [gridColumns] is set.
  final double gridCellSpacing;

  /// Optional handler for ←/→ on the currently highlighted item in list
  /// mode. Returning true marks the keys as handled; returning false lets
  /// them flow on (currently unused). Not invoked in grid mode, where
  /// ←/→ already address grid navigation.
  final Future<bool> Function(T item, int delta)? onSecondaryAxis;

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
    Widget? subtitleWidget,
    Future<bool> Function(BuildContext context, T item, String searchText)?
    onSelect,
    String? emptyMessage,
    void Function(Future<void> Function() refresh)? onRefreshNeeded,
    void Function(T item)? onHighlightChanged,
    bool? showFilter,
    Future<T?> Function(BuildContext context)? onAdd,
    String? addTooltip,
    bool Function(T item, String search)? filter,
    bool clearSearchOnRefresh = false,
    int? gridColumns,
    double gridCellSize = 36,
    double gridCellSpacing = 4,
    Future<bool> Function(T item, int delta)? onSecondaryAxis,
    BoxConstraints? constraints,
  }) async {
    // Pre-fetch items for empty search so the modal opens fully populated.
    // Callers typically invoke this from inside a Command run, so the trigger
    // item's icon naturally shows its own spinner during this await — much
    // less jarring than flashing an empty modal with a spinner inside.
    List<SelectGroup<T>>? initialItems;
    try {
      initialItems = await items(null);
    } catch (e, t) {
      log.warning('Error pre-fetching items', e, t);
      // Continue anyway — the modal will fall back to its own loading state.
    }

    if (!context.mounted) {
      return Value.absent();
    }

    final result = await SelectModal<T>(
      items: items,
      itemBuilder: itemBuilder,
      selectedValue: selectedValue,
      title: title,
      prompt: prompt,
      subtitle: subtitle,
      subtitleWidget: subtitleWidget,
      onSelect: onSelect,
      initialItems: initialItems,
      emptyMessage: emptyMessage,
      onRefreshNeeded: onRefreshNeeded,
      onHighlightChanged: onHighlightChanged,
      showFilter: showFilter,
      onAdd: onAdd,
      addTooltip: addTooltip,
      filter: filter,
      clearSearchOnRefresh: clearSearchOnRefresh,
      gridColumns: gridColumns,
      gridCellSize: gridCellSize,
      gridCellSpacing: gridCellSpacing,
      onSecondaryAxis: onSecondaryAxis,
      constraints: constraints ??
          const BoxConstraints(maxHeight: 640, maxWidth: 750),
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
    this.subtitleWidget,
    this.onSelect,
    this.initialItems,
    this.emptyMessage,
    this.onRefreshNeeded,
    this.onHighlightChanged,
    this.showFilter,
    this.onAdd,
    this.addTooltip,
    this.filter,
    this.clearSearchOnRefresh = false,
    this.gridColumns,
    this.gridCellSize = 36,
    this.gridCellSpacing = 4,
    this.onSecondaryAxis,
  });

  final Future<List<SelectGroup<T>>> Function(String? search) items;
  final Widget Function(T, bool isLoading) itemBuilder;
  final T? selectedValue;
  final String? title;
  final String? prompt;
  final String? subtitle;
  final Widget? subtitleWidget;
  final Future<bool> Function(BuildContext context, T item, String searchText)?
  onSelect;
  final List<SelectGroup<T>>? initialItems;
  final String? emptyMessage;
  final void Function(Future<void> Function() refresh)? onRefreshNeeded;
  final void Function(T item)? onHighlightChanged;
  final bool? showFilter;
  final Future<T?> Function(BuildContext context)? onAdd;
  final String? addTooltip;
  final bool Function(T item, String search)? filter;
  final bool clearSearchOnRefresh;
  final int? gridColumns;
  final double gridCellSize;
  final double gridCellSpacing;
  final Future<bool> Function(T item, int delta)? onSecondaryAxis;

  @override
  _SelectModalState<T> createState() => _SelectModalState<T>();
}

class _SelectModalState<T> extends State<_SelectModal<T>> {
  /// Per-flat-index GlobalKeys for grid-mode rows. Used by [_scrollToIndex]
  /// to call [Scrollable.ensureVisible] on the actual rendered row, which
  /// counts headers from real layout rather than estimating their height.
  final Map<int, GlobalKey> _gridCellKeys = {};

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
  // Last flat index dispatched to [widget.onHighlightChanged]; guards against
  // re-firing while the highlight sits on the same row across rebuilds.
  int? _lastNotifiedHighlight;
  bool _isRefreshing = false;
  bool _mouseHasMoved = false;
  bool _enterHandled =
      false; // Prevents double-fire between Shortcuts and onSubmit
  int? _loadingIndex;
  Timer? _spinnerDelay;
  // In-field activity indicator shown while a data-source fetch is in flight
  // even when prior results are still displayed (deferred via [_fetchIndicatorDelay]
  // so fast fetches don't flash a spinner). Distinct from [_isLoading], which
  // is the cold-load state that replaces the whole list.
  bool _isFetching = false;
  Timer? _fetchIndicatorDelay;
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
    // Multi-select pickers reset the filter on each run so the freshly toggled
    // selection — and all existing ones — become visible again. Clearing the
    // text here makes the re-fetch below take the empty-search path.
    if (widget.clearSearchOnRefresh && _controller.text.isNotEmpty) {
      _controller.clear();
    }
    // Clear cache to force re-fetch on refresh
    _emptySearchCache = null;
    _isRefreshing = true;
    await _runFetch();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _spinnerDelay?.cancel();
    _fetchIndicatorDelay?.cancel();
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
    _fetchIndicatorDelay?.cancel();
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
      _isFetching = false;
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
        _fetchIndicatorDelay?.cancel();
        setState(() {
          _error = null;
          _isLoading = false;
          _isFetching = false;
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

      // In-field activity indicator: surfaces in-flight fetches even when prior
      // results are still on screen (so the list isn't cleared mid-type).
      // Deferred so fast fetches don't flash. Each keystroke cancels the prior
      // timer and restarts it; stale fetches leave the flag for the newest one.
      _fetchIndicatorDelay?.cancel();
      _fetchIndicatorDelay = Timer(_spinnerDelayDuration, () {
        if (_isDisposed) return;
        setState(() => _isFetching = true);
      });

      final currentRequestId = ++_requestId;

      final groupsList = await widget.items(searchText);

      if (_isDisposed) return;

      // Discard stale results — a newer fetch is in flight and owns the
      // in-field indicator, so don't clear it here.
      if (currentRequestId != _requestId) return;

      _spinnerDelay?.cancel();
      _fetchIndicatorDelay?.cancel();

      setState(() {
        _error = null;
        _isLoading = false;
        _isFetching = false;
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
        _fetchIndicatorDelay?.cancel();
        setState(() {
          _error = 'Loading failed.';
          _isLoading = false;
          _isFetching = false;
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
    // With a physical keyboard, always show the filter so users can type to
    // search without first having to reach for the field. The item-count
    // threshold below only applies on touch-only devices.
    if (hasPhysicalKeyboard()) return true;
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

  /// Move the highlight along the grid's vertical axis. The flat-index step
  /// equals the cell count of the row we're leaving (down) or entering
  /// (up), so a partial trailing row of N < cols cells advances by N — not
  /// by cols — and the cursor lands on the same column in the adjacent
  /// row instead of skipping it.
  void _moveHighlightGridVertical(int rowOffset) {
    final cols = widget.gridColumns;
    if (cols == null || cols < 1) {
      _moveHighlight(rowOffset);
      return;
    }
    final totalDisplay = _getTotalDisplayCount();
    if (totalDisplay == 0) return;

    int target = _highlightedIndex;
    final direction = rowOffset.sign;
    var remaining = rowOffset.abs();
    while (remaining > 0) {
      final step = _gridVerticalStep(target, direction, cols);
      if (step == 0) break;
      target += direction * step;
      remaining--;
      if (target < 0 || target >= totalDisplay) break;
    }
    target = target.clamp(0, totalDisplay - 1);
    if (target == _highlightedIndex) return;
    setState(() => _highlightedIndex = target);
    _scrollToIndex(_highlightedIndex);
  }

  /// How many flat indices to advance when moving vertically from [index]
  /// in [direction] (`+1` down, `-1` up). Returns 0 when there's nothing
  /// to step into.
  ///
  /// - Down: step = cells in the row containing [index].
  /// - Up:   step = cells in the row immediately above the row containing
  ///   [index] (or 1 for an info-only slot above).
  /// - Info-only slots are treated as full-width rows of size 1.
  int _gridVerticalStep(int index, int direction, int cols) {
    final totalDisplay = _getTotalDisplayCount();
    if (index < 0 || index >= totalDisplay) return 0;
    if (direction > 0) {
      if (_isInfoOnlySlot(index)) return 1;
      return _gridRowCellCount(index, cols);
    } else {
      final rowFirst = _gridRowFirstIndex(index, cols);
      if (rowFirst == 0) return 0;
      final prevIndex = rowFirst - 1;
      if (_isInfoOnlySlot(prevIndex)) return 1;
      return _gridRowCellCount(prevIndex, cols);
    }
  }

  /// Number of cells in the grid row that contains [index]. Partial
  /// trailing rows return their actual cell count, not [cols].
  int _gridRowCellCount(int index, int cols) {
    int cursor = 0;
    for (final group in _groups) {
      if (group.items.isEmpty && group.infoBuilder != null) {
        if (index == cursor) return 1;
        cursor++;
        continue;
      }
      if (index < cursor + group.items.length) {
        final positionInGroup = index - cursor;
        final rowStartInGroup = (positionInGroup ~/ cols) * cols;
        return math.min(cols, group.items.length - rowStartInGroup);
      }
      cursor += group.items.length;
    }
    return cols;
  }

  /// Flat index of the first cell in the grid row that contains [index].
  int _gridRowFirstIndex(int index, int cols) {
    int cursor = 0;
    for (final group in _groups) {
      if (group.items.isEmpty && group.infoBuilder != null) {
        if (index == cursor) return cursor;
        cursor++;
        continue;
      }
      if (index < cursor + group.items.length) {
        final positionInGroup = index - cursor;
        final rowStartInGroup = (positionInGroup ~/ cols) * cols;
        return cursor + rowStartInGroup;
      }
      cursor += group.items.length;
    }
    return index;
  }

  /// Scrolls to ensure the item at the given index is visible.
  /// Only scrolls if the item is outside or near the viewport edges.
  /// When scrolling down, ensures the next item is also visible for better UX.
  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      // Grid mode: when the target cell is built, use its real RenderBox
      // position so headers (variable height) and any future intra-list
      // chrome are accounted for from layout, not estimated. Falls through
      // to the estimate path when the cell isn't currently in the tree
      // (e.g. far off-screen jumps after search clear).
      final cols = widget.gridColumns;
      if (cols != null) {
        final ctx = _gridCellKeys[index]?.currentContext;
        final cellBox = ctx?.findRenderObject() as RenderBox?;
        final viewportCtx =
            _scrollController.position.context.notificationContext;
        final viewportBox = viewportCtx?.findRenderObject() as RenderBox?;
        if (cellBox != null && viewportBox != null) {
          final cellTopInViewport =
              cellBox.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
          final cellHeight = cellBox.size.height;
          final viewportHeight = _scrollController.position.viewportDimension;
          final currentOffset = _scrollController.offset;
          final maxScroll = _scrollController.position.maxScrollExtent;

          double? target;
          if (cellTopInViewport < 0) {
            // Cell is above viewport — scroll up so its top sits at the
            // viewport top.
            target = currentOffset + cellTopInViewport;
          } else if (cellTopInViewport + cellHeight > viewportHeight) {
            // Cell is below viewport — scroll down so its bottom sits at
            // the viewport bottom.
            target = currentOffset +
                (cellTopInViewport + cellHeight - viewportHeight);
          }
          if (target != null) {
            _scrollController.animateTo(
              target.clamp(0.0, maxScroll),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
          return;
        }
      }

      // List mode (or grid fallback): estimate row pixel position from a
      // fixed per-row height.
      final double estimatedItemHeight = cols != null
          ? (widget.gridCellSize + widget.gridCellSpacing)
          : 50.0;
      final int rowIndex = cols != null ? (index ~/ cols) : index;

      // Special case: scroll to top for first item to show headers/info
      if (index == 0) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        return;
      }

      final estimatedOffset = rowIndex * estimatedItemHeight;
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

  /// Forward ←/→ on the highlighted row to [widget.onSecondaryAxis], if
  /// supplied. Silently no-op when the handler isn't provided, the
  /// highlight is on an info-only slot, or out of range — that way the
  /// keys don't interfere with non-secondary-axis modals.
  void _invokeSecondaryAxis(int delta) {
    final handler = widget.onSecondaryAxis;
    if (handler == null) return;
    final totalDisplay = _getTotalDisplayCount();
    if (_highlightedIndex < 0 || _highlightedIndex >= totalDisplay) return;
    if (_isInfoOnlySlot(_highlightedIndex)) return;
    final item = _getItemAtIndexUnsafe(_highlightedIndex);
    handler(item, delta);
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
      _selectItem(_getItemAtIndexUnsafe(_highlightedIndex), _highlightedIndex);
    }
  }

  /// Build the grid-mode list. Each entry in the flat plan is either a
  /// header / info row (full-width) or a "row of cells" containing up to
  /// `gridColumns` items. The flat highlight index still addresses items
  /// (matching list mode), so the same scroll-to-index logic works after
  /// translating flat-index → row-index.
  Widget _buildGridList(ListViewSelectorController listController) {
    final cols = widget.gridColumns!;
    final cellSize = widget.gridCellSize;
    final cellSpacing = widget.gridCellSpacing;

    final entries = <_GridPlanEntry<T>>[];
    int flatIdx = 0;
    String? prevTitle;
    for (final group in _groups) {
      if (group.title != null && group.title != prevTitle) {
        entries.add(_GridHeaderEntry<T>(group));
      }
      prevTitle = group.title;
      if (group.items.isEmpty && group.infoBuilder != null) {
        entries.add(_GridInfoEntry<T>(group, flatIdx));
        flatIdx++;
        continue;
      }
      for (var i = 0; i < group.items.length; i += cols) {
        final rowItems = <(T, int)>[];
        for (var j = i; j < math.min(i + cols, group.items.length); j++) {
          rowItems.add((group.items[j], flatIdx));
          flatIdx++;
        }
        entries.add(_GridRowEntry<T>(rowItems));
      }
    }

    return ListView.builder(
      controller: _scrollController,
      shrinkWrap: true,
      itemCount: entries.length,
      itemBuilder: (context, rowIndex) {
        final entry = entries[rowIndex];
        switch (entry) {
          case _GridHeaderEntry<T>():
            return _buildGroupHeader(entry.group);
          case _GridInfoEntry<T>():
            return _buildGridInfoSlot(entry.group, entry.flatIndex,
                listController, cellSize);
          case _GridRowEntry<T>():
            // Symmetric vertical padding keeps the actual row height equal
            // to (cellSize + cellSpacing) — the same value `_scrollToIndex`
            // uses to estimate position, so keyboard scroll-into-view lands
            // exactly on the cell.
            //
            // Each row is rendered inside a fixed-width SizedBox sized to a
            // full row (cols * cellSize + gaps) and centered. Within that
            // block, cells stack from the left, so a short trailing row
            // (e.g. last 3 emoji in a category) lines up with the rows
            // above instead of drifting to the visual centre.
            final blockWidth =
                cols * cellSize + (cols - 1) * cellSpacing;
            return Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                cellSpacing / 2,
                12,
                cellSpacing / 2,
              ),
              child: Center(
                child: SizedBox(
                  width: blockWidth,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      for (var i = 0; i < entry.cells.length; i++) ...[
                        if (i > 0) SizedBox(width: cellSpacing),
                        _buildGridCell(
                          entry.cells[i].$1,
                          entry.cells[i].$2,
                          listController,
                          cellSize,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
        }
      },
    );
  }

  Widget _buildGroupHeader(SelectGroup<T> group) {
    return Padding(
      padding: context.theme.spacing.paddingSm.copyWith(
        right: context.theme.spacing.xxl,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              group.title!,
              style: TextStyle(
                color: context.theme.colors.mutedForeground,
                fontSize: context.theme.typography.sm.fontSize,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (group.hint != null && hasPhysicalKeyboard())
            Text(
              group.hint!,
              style: TextStyle(
                color: context.theme.colors.mutedForeground,
                fontSize: context.theme.typography.xs.fontSize,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGridInfoSlot(
    SelectGroup<T> group,
    int flatIndex,
    ListViewSelectorController listController,
    double cellSize,
  ) {
    final info = group.infoBuilder!(context);
    if (info == null) return const SizedBox.shrink();
    final isHighlighted = flatIndex == _highlightedIndex;
    return MouseRegion(
      onEnter: (_) {
        if (!_mouseHasMoved) return;
        listController.setHovered(flatIndex);
        setState(() => _highlightedIndex = flatIndex);
      },
      onExit: (_) {
        if (!_mouseHasMoved) return;
        listController.setHovered(null);
        setState(() => _highlightedIndex = -1);
      },
      onHover: (_) {
        if (!_mouseHasMoved) {
          setState(() => _mouseHasMoved = true);
          listController.setHovered(flatIndex);
          setState(() => _highlightedIndex = flatIndex);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: group.onActivate != null
            ? () => group.onActivate!(context)
            : null,
        child: Container(
          decoration: BoxDecoration(
            color: isHighlighted ? context.theme.colors.secondary : null,
          ),
          child: info,
        ),
      ),
    );
  }

  Widget _buildGridCell(
    T item,
    int flatIndex,
    ListViewSelectorController listController,
    double cellSize,
  ) {
    final isItemLoading = _loadingIndex == flatIndex;
    final highlighted = flatIndex == _highlightedIndex;
    final inner = widget.itemBuilder(item, isItemLoading);
    final cellKey = _gridCellKeys.putIfAbsent(flatIndex, () => GlobalKey());
    return MouseRegion(
      key: cellKey,
      onEnter: (_) {
        if (!_mouseHasMoved) return;
        listController.setHovered(flatIndex);
        setState(() => _highlightedIndex = flatIndex);
      },
      onExit: (_) {
        if (!_mouseHasMoved) return;
        listController.setHovered(null);
        setState(() => _highlightedIndex = -1);
      },
      onHover: (_) {
        if (!_mouseHasMoved) {
          setState(() => _mouseHasMoved = true);
          listController.setHovered(flatIndex);
          setState(() => _highlightedIndex = flatIndex);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: isItemLoading ? null : () => _selectItem(item, flatIndex),
        child: Container(
          width: cellSize,
          height: cellSize,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: highlighted ? context.theme.colors.secondary : null,
          ),
          child: inner,
        ),
      ),
    );
  }

  /// Selects [item], which is displayed at [displayIndex] in the flat item
  /// list. The loading spinner is keyed on [displayIndex] (the actually
  /// tapped/activated row) rather than [_highlightedIndex], so it lands on the
  /// right row even when the pointer never hovered first — e.g. a touch tap or
  /// the modal opening directly under the cursor (no hover means
  /// [_highlightedIndex] is still its initial 0).
  Future<void> _selectItem(T item, int displayIndex) async {
    if (_loadingIndex != null) return; // Already loading
    if (widget.onSelect != null) {
      setState(() => _loadingIndex = displayIndex);
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
        Tracker.captureException(e, t);
        if (mounted) {
          setState(() => _loadingIndex = null);
          context.showToast(
            message: 'Something went wrong. Please try again.',
            isError: true,
          );
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

  /// Dispatch [widget.onHighlightChanged] for the currently highlighted row,
  /// at most once per distinct highlight. Skips info-only slots and
  /// out-of-range indices (mirrors the Enter-activation guards). Scheduled from
  /// [build] via a post-frame callback so the callback — which may kick off
  /// work in the parent — never runs during build.
  void _maybeNotifyHighlight() {
    final onChanged = widget.onHighlightChanged;
    if (onChanged == null) return;
    final index = _highlightedIndex;
    if (index == _lastNotifiedHighlight) return;
    if (index < 0 || index >= _getTotalDisplayCount()) return;
    if (_isInfoOnlySlot(index)) return;
    _lastNotifiedHighlight = index;
    onChanged(_getItemAtIndexUnsafe(index));
  }

  @override
  Widget build(BuildContext context) {
    // Notify the parent once the highlight settles (after this frame lays out),
    // so it can prefetch the row the user is likely to activate. Only scheduled
    // when a listener is present — no cost for the common no-callback case.
    if (widget.onHighlightChanged != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isDisposed) _maybeNotifyHighlight();
      });
    }

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
          _selectItem(_getItemAtIndexUnsafe(index), index);
        }
      },
      builder: (context, listController) {
        // Set bounds for the controller
        listController.clamp(0, displayCount - 1);

        final isGrid = widget.gridColumns != null;
        return Shortcuts(
          shortcuts: isGrid
              ? const {
                  SingleActivator(LogicalKeyboardKey.arrowUp):
                      _GridMoveIntent.up,
                  SingleActivator(LogicalKeyboardKey.arrowDown):
                      _GridMoveIntent.down,
                  SingleActivator(LogicalKeyboardKey.arrowLeft):
                      _GridMoveIntent.left,
                  SingleActivator(LogicalKeyboardKey.arrowRight):
                      _GridMoveIntent.right,
                  SingleActivator(LogicalKeyboardKey.enter):
                      ActivateListSelectionIntent(),
                  SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
                }
              : const {
                  SingleActivator(LogicalKeyboardKey.arrowUp):
                      MoveListSelectionIntent(-1),
                  SingleActivator(LogicalKeyboardKey.arrowDown):
                      MoveListSelectionIntent(1),
                  SingleActivator(LogicalKeyboardKey.arrowLeft):
                      _SecondaryAxisIntent(-1),
                  SingleActivator(LogicalKeyboardKey.arrowRight):
                      _SecondaryAxisIntent(1),
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
              _SecondaryAxisIntent: CallbackAction<_SecondaryAxisIntent>(
                onInvoke: (intent) {
                  _invokeSecondaryAxis(intent.delta);
                  return KeyEventResult.handled;
                },
              ),
              _GridMoveIntent: CallbackAction<_GridMoveIntent>(
                onInvoke: (intent) {
                  switch (intent.direction) {
                    case 'left':
                      _moveHighlight(-1);
                    case 'right':
                      _moveHighlight(1);
                    case 'up':
                      _moveHighlightGridVertical(-1);
                    case 'down':
                      _moveHighlightGridVertical(1);
                  }
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
                      builder: (context, focusNode) => ValueListenableBuilder<int>(
                        valueListenable: ModalProvider.of(
                          context,
                        ).modalStackNotifier,
                        builder: (context, stackLength, child) => Padding(
                          // When this modal is at the top of the stack, leave
                          // room on the right for the floating close button
                          // rendered by [Modal] so it doesn't overlap the
                          // search field or the optional `+` button.
                          padding: context.theme.spacing.padding.copyWith(
                            right: stackLength <= 1
                                ? context.theme.spacing.padding.right +
                                    modalCloseButtonReservedWidth
                                : context.theme.spacing.padding.right,
                          ),
                          child: Row(
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
                                    Expanded(
                                      child: TextField(
                                        maxLines: 1,
                                        style: TextFieldStyle.ghost,
                                        controller: _controller,
                                        autofocus: hasPhysicalKeyboard(),
                                        label: widget.prompt != null
                                            ? "${widget.prompt}…"
                                            : "Search…",
                                        focusNode: focusNode,
                                        onChanged: (text) => _initItems(),
                                        onSubmitted: (_) => _handleEnter(),
                                      ),
                                    ),
                                    // In-field activity indicator while a fetch
                                    // is in flight — keeps the displayed list
                                    // visible and signals that filtering is
                                    // still working.
                                    if (_isFetching)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 8),
                                        child: Spinner(
                                          size: context.theme.iconSizes.sm,
                                          color: context
                                              .theme
                                              .colors
                                              .mutedForeground,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (widget.onAdd != null)
                                Builder(
                                  builder: (context) {
                                    final addButton = FButton.icon(
                                      variant: FButtonVariant.ghost,
                                      onPress: () => _handleAdd(context),
                                      child: Icon(
                                        PlotIcon.add,
                                        size: context.theme.iconSizes.sm,
                                      ),
                                    );
                                    if (widget.addTooltip == null) {
                                      return addButton;
                                    }
                                    return FTooltip(
                                      tipBuilder: (ctx, _) =>
                                          Text(widget.addTooltip!),
                                      child: addButton,
                                    );
                                  },
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
                                // Top-level, header-less list (e.g. the mobile
                                // "More" menu with no filter bar). Reserve top
                                // space so the floating close button rendered
                                // by [Modal] doesn't overlap the first row.
                                return const SizedBox(
                                  height: modalCloseButtonReservedHeight,
                                );
                              }
                              return Padding(
                                // Reserve room on the right for the floating
                                // close button when this modal is top-level.
                                // Use the full `padding` (not `paddingSm`) so
                                // the title's vertical centre matches the
                                // floating close button — the same metrics the
                                // search-field header path uses. `paddingSm`'s
                                // tighter vertical inset left the title centred
                                // above the X.
                                padding: context.theme.spacing.padding.copyWith(
                                  right: nested
                                      ? context.theme.spacing.padding.right
                                      : context.theme.spacing.padding.right +
                                            modalCloseButtonReservedWidth,
                                ),
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
                  if (widget.subtitleWidget != null)
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
                        child: widget.subtitleWidget!,
                      ),
                    )
                  else if (widget.subtitle != null)
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
                          // Derive from the theme's `sm` text style so the
                          // subtitle inherits the app's font family and
                          // weight; a raw TextStyle that only sets color +
                          // fontSize falls back to the platform default
                          // weight (heavy on iOS), unlike body copy elsewhere.
                          style: context.theme.typography.sm.copyWith(
                            color: context.theme.colors.mutedForeground,
                          ),
                        ),
                      ),
                    ),
                  ?errorBox,
                  Flexible(
                    child: ScrollEdgeFade(
                      background: context.theme.colors.background,
                      child: widget.gridColumns != null
                        ? _buildGridList(listController)
                        : ListView.builder(
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
                              ?infoHeader,
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
                                    : () => _selectItem(item, index),
                                child: itemWidget,
                              );

                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ?header,
                            ?info,
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
                  ),
                  ?loadingIndicator,

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

/// Directional move within a grid-mode SelectModal. List mode reuses the
/// existing [MoveListSelectionIntent] with ±1 offsets. The unique [direction]
/// value gives each constant a distinct identity so `Shortcuts`/`Actions`
/// dispatch can pick the right callback.
class _GridMoveIntent extends Intent {
  const _GridMoveIntent._(this.direction);
  final String direction;

  static const _GridMoveIntent up = _GridMoveIntent._('up');
  static const _GridMoveIntent down = _GridMoveIntent._('down');
  static const _GridMoveIntent left = _GridMoveIntent._('left');
  static const _GridMoveIntent right = _GridMoveIntent._('right');
}

/// Cycle the highlighted row's secondary axis (e.g. a contact's role).
/// Fired by ←/→ in list mode when the modal was given an
/// [SelectModal.onSecondaryAxis] handler.
class _SecondaryAxisIntent extends Intent {
  const _SecondaryAxisIntent(this.delta);
  final int delta;
}

/// Render plan for grid mode. Each ListView row is one entry.
sealed class _GridPlanEntry<T> {
  const _GridPlanEntry();
}

class _GridHeaderEntry<T> extends _GridPlanEntry<T> {
  const _GridHeaderEntry(this.group);
  final SelectGroup<T> group;
}

class _GridInfoEntry<T> extends _GridPlanEntry<T> {
  const _GridInfoEntry(this.group, this.flatIndex);
  final SelectGroup<T> group;
  final int flatIndex;
}

class _GridRowEntry<T> extends _GridPlanEntry<T> {
  const _GridRowEntry(this.cells);
  /// Pairs of (item, flatIndex). Length ≤ gridColumns.
  final List<(T, int)> cells;
}

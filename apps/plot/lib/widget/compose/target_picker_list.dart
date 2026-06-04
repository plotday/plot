import 'dart:async';

// OutlineInputBorder is used to make the filter field borderless in every
// state (BorderSide.none), letting the fading underline be the only chrome.
// Imported with `show` per the established pattern in widget/text_field.dart
// and widget/date_input.dart.
import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/command/command.dart'
    show BuildContextCommandExtension, ManageConnections;
import 'package:plot/state/compose_targets.dart';
import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/store/store.dart' show Actor;
import 'package:plot/widget/compose/compose_target_view.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';
// ListViewSelector + its controller; the MoveListSelectionIntent /
// ActivateListSelectionIntent classes are also exported by widget.dart (via
// infinite_list.dart), so hide the duplicates here and use the barrel's.
import 'package:plot/widget/list_view_selector.dart'
    show ListViewSelector, ListViewSelectorController;
import 'package:plot/widget/widget.dart';

/// The step-1 **target picker** body: a search box over the
/// [ComposeTargetsBloc] ranked list with keyboard navigation (↑/↓ highlight,
/// Enter select, type-to-filter).
///
/// Built on low-level primitives ([ListViewSelector] + [Shortcuts]/[Actions])
/// rather than the [Modal]-coupled `_SelectModal`, so it mounts inline on the
/// compose page (step 1) without depending on `Modal.pop`/`ModalProvider`.
/// Tapping the step-2 Connection field navigates back to this same surface (a
/// plain "go back"), so there is a single styled picker rather than a separate
/// modal variant.
///
/// Selection is reported via [onSelect]; the host applies the target and
/// advances to step 2. Search routes through [ComposeTargetsBloc.search]; the
/// base list comes from the bloc's state (populate it via
/// [ComposeTargetsBloc.refresh] before opening). When [searchController] is
/// supplied with pre-filled text, the picker filters on mount so a restored
/// filter shows its filtered results immediately.
class TargetPickerList extends StatefulWidget {
  const TargetPickerList({
    super.key,
    required this.onSelect,
    required this.scrollController,
    this.listFocusNode,
    this.searchController,
    this.searchFocusNode,
    this.autofocusSearch = true,
  });

  /// Invoked with the chosen target on Enter/tap.
  final void Function(ComposeTarget target) onSelect;

  /// Scroll controller for the list (owned by the host so step-2 re-open can
  /// reuse a fresh one).
  final ScrollController scrollController;

  /// Focus node used to capture arrow/Enter keys when the search field is
  /// hidden (touch). Optional — a local node is created when null.
  final FocusNode? listFocusNode;

  /// Search text controller. Optional — a local one is created when null.
  final TextEditingController? searchController;

  /// Focus node for the search field. Optional — a local one is created when
  /// null. The host can supply (and retain) one so it can re-focus the field
  /// when it resets an already-open page back to step 1 (see
  /// [NewThreadPageState._resetToFreshStart]).
  final FocusNode? searchFocusNode;

  /// Whether to autofocus the search field on mount (so type-to-filter works
  /// immediately). Only honored on physical-keyboard platforms.
  final bool autofocusSearch;

  @override
  State<TargetPickerList> createState() => _TargetPickerListState();
}

class _TargetPickerListState extends State<TargetPickerList> {
  late final TextEditingController _controller =
      widget.searchController ?? TextEditingController();
  late final bool _ownsController = widget.searchController == null;
  late final FocusNode _listFocusNode =
      widget.listFocusNode ?? FocusNode(debugLabel: 'TargetPickerList-list');
  late final bool _ownsFocusNode = widget.listFocusNode == null;
  late final FocusNode _searchFocusNode =
      widget.searchFocusNode ??
      FocusNode(debugLabel: 'TargetPickerList-search');
  late final bool _ownsSearchFocusNode = widget.searchFocusNode == null;

  /// Estimated height of a two-line row (focus-tinted header + content line +
  /// the comfortable vertical padding + inter-row gap), used only by the
  /// keyboard-nav scroll-into-view math; a slight over-estimate is safe (it
  /// scrolls a touch more than needed, never less).
  static const double _estimatedItemHeight = 68.0;

  /// Results currently displayed. Seeded from the bloc's base list and
  /// replaced by [ComposeTargetsBloc.search] as the user types.
  List<ComposeTargetView> _results = const [];
  int _highlightedIndex = 0;
  bool _mouseHasMoved = false;
  bool _isDisposed = false;
  int _requestId = 0;

  /// Trimmed search text whose results are displayed. Used to flush an
  /// in-flight search on Enter so we activate against fresh results.
  String _appliedSearch = '';
  Future<void>? _lastSearch;
  bool _enterHandled = false;

  /// Debounce timer for the filter field. Each [ComposeTargetsBloc.search] runs
  /// DB work, so we collapse a burst of keystrokes into a single search once the
  /// user pauses (see [_onSearchChanged]).
  Timer? _debounce;

  /// How long to wait after the last keystroke before searching. Short enough
  /// to feel instantaneous on a pause, long enough to skip the intermediate
  /// queries while the user is actively typing.
  static const Duration _searchDebounce = Duration(milliseconds: 180);

  @override
  void initState() {
    super.initState();
    _results = context.read<ComposeTargetsBloc>().state.targets;
    // When mounted with a pre-filled (restored) filter — e.g. the user tapped
    // the step-2 Connection field to come back and change the connection — run
    // the search once so the restored text shows its filtered results
    // immediately instead of the unfiltered base list. Deferred a frame so the
    // setState inside [_runSearch] lands after mount.
    if (_controller.text.trim().isNotEmpty) {
      _appliedSearch = _controller.text.trim();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isDisposed) _runSearch();
      });
    }
  }

  /// Re-seed the displayed results from the bloc's freshly-emitted base list.
  ///
  /// Only fires on the empty-query path — when the user has typed a search,
  /// [_runSearch] owns [_results] and a base-list re-emit (e.g. from
  /// [ComposeTargetsBloc.prependToCache] after a thread is created) must not
  /// clobber the active filter/synthesis. On a fresh open the base list is
  /// usually still empty when this widget mounts (the page fires
  /// [ComposeTargetsBloc.refresh] fire-and-forget), so this listener is what
  /// surfaces the rows (focuses, people, twists, connectors) once `refresh()`
  /// resolves.
  void _onBaseListChanged(ComposeTargetsState state) {
    if (_isDisposed) return;
    if (_controller.text.trim().isNotEmpty) return;
    setState(() {
      _results = state.targets;
      _appliedSearch = '';
      // Clamp against [_rowCount] (real targets + the synthetic add-connection
      // row) so the highlight can land on the add-row even when the list is
      // otherwise empty.
      _highlightedIndex = _highlightedIndex.clamp(0, _rowCount - 1);
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    _debounce?.cancel();
    if (_ownsFocusNode) _listFocusNode.dispose();
    if (_ownsController) _controller.dispose();
    if (_ownsSearchFocusNode) _searchFocusNode.dispose();
    super.dispose();
  }

  /// Field-change handler: debounce non-empty queries so we issue one search
  /// per typing pause rather than one per keystroke. Emptying the field (or
  /// clearing it) searches immediately — that path just returns the cached base
  /// list, so there's nothing to debounce and the list should snap back at once.
  void _onSearchChanged() {
    _debounce?.cancel();
    if (_controller.text.trim().isEmpty) {
      _runSearch();
      return;
    }
    _debounce = Timer(_searchDebounce, () {
      if (_isDisposed) return;
      _runSearch();
    });
  }

  Future<void> _runSearch() {
    final query = _controller.text;
    final requestId = ++_requestId;
    final future = context
        .read<ComposeTargetsBloc>()
        .search(query)
        .then((results) {
          if (_isDisposed || requestId != _requestId) return;
          setState(() {
            _results = results;
            _appliedSearch = query.trim();
            // Clamp against [_rowCount] so the add-connection row stays reachable
            // (and becomes the sole, highlightable row when nothing matches).
            _highlightedIndex = _highlightedIndex.clamp(0, _rowCount - 1);
          });
        })
        .catchError((Object e, StackTrace s) {
          Tracker.captureException(e, s);
        });
    return _lastSearch = future;
  }

  /// Awaits the in-flight search (and any successor) so Enter acts on results
  /// matching the fully-typed text.
  Future<void> _flushPendingSearch() async {
    // Collapse a pending debounce: Enter must search the fully-typed text now
    // rather than wait out the remaining debounce window.
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      _runSearch();
    }
    while (_lastSearch != null) {
      final fut = _lastSearch;
      await fut;
      if (_isDisposed) return;
      if (identical(fut, _lastSearch)) break;
    }
    if (_isDisposed) return;
    if (_controller.text.trim() == _appliedSearch) return;
    await _runSearch();
  }

  /// Index of the synthetic "+ Add a connection…" row, which always sits last
  /// (after every real target). See [_buildAddConnectionRow] / tweak 7.
  int get _addConnectionIndex => _results.length;

  /// Total navigable rows: every real target plus the always-present
  /// add-connection row.
  int get _rowCount => _results.length + 1;

  void _moveHighlight(int offset) {
    setState(() {
      _highlightedIndex = (_highlightedIndex + offset).clamp(0, _rowCount - 1);
    });
    _scrollToIndex(_highlightedIndex);
  }

  void _scrollToIndex(int index) {
    if (!widget.scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.scrollController.hasClients) return;
      if (index == 0) {
        widget.scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        return;
      }
      final estimatedOffset = index * _estimatedItemHeight;
      final viewportHeight = widget.scrollController.position.viewportDimension;
      final currentScroll = widget.scrollController.offset;
      final maxScroll = widget.scrollController.position.maxScrollExtent;
      if (estimatedOffset < currentScroll) {
        widget.scrollController.animateTo(
          estimatedOffset,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else if (estimatedOffset + (_estimatedItemHeight * 2) >
          currentScroll + viewportHeight) {
        widget.scrollController.animateTo(
          (estimatedOffset + (_estimatedItemHeight * 2) - viewportHeight).clamp(
            0.0,
            maxScroll,
          ),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleEnter() async {
    if (_enterHandled) return;
    _enterHandled = true;
    Future.microtask(() => _enterHandled = false);

    if (_controller.text.trim() != _appliedSearch ||
        _lastSearch != null ||
        (_debounce?.isActive ?? false)) {
      await _flushPendingSearch();
    }
    if (!mounted) return;
    // The synthetic add-connection row sits at [_addConnectionIndex]; Enter on
    // it opens the connections manager rather than selecting a target.
    if (_highlightedIndex == _addConnectionIndex) {
      _runManageConnections();
      return;
    }
    if (_highlightedIndex < 0 || _highlightedIndex >= _results.length) return;
    widget.onSelect(_results[_highlightedIndex].target);
  }

  /// Opens the connections manager ([ManageConnections]) from the synthetic
  /// "+ Add a connection…" row (tweak 7). Runs through the page's command
  /// runner so it routes through the modal stack like every other command.
  void _runManageConnections() {
    final runner = context;
    unawaited(() async {
      try {
        await runner.run(ManageConnections());
      } catch (e, s) {
        Tracker.captureException(e, s);
      }
    }());
  }

  /// Clears the filter (the trailing ✕): empties the controller and re-runs the
  /// search so the full base list returns, keeping focus on the field so the
  /// user can keep typing.
  void _clearSearch() {
    _debounce?.cancel();
    _controller.clear();
    _runSearch();
    _searchFocusNode.requestFocus();
  }

  /// Escape clears the filter (keeping focus on the bar) when it has text.
  /// When the field is already empty, Escape is left to propagate so a parent
  /// (e.g. the hosting modal) can dismiss as usual.
  KeyEventResult _onSearchFieldKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _controller.text.isNotEmpty) {
      _clearSearch();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ComposeTargetsBloc, ComposeTargetsState>(
      listenWhen: (prev, curr) => prev.targets != curr.targets,
      listener: (_, state) => _onBaseListChanged(state),
      child: _buildList(context),
    );
  }

  Widget _buildList(BuildContext context) {
    return ListViewSelector(
      scrollController: widget.scrollController,
      estimatedItemHeight: _estimatedItemHeight,
      onActivate: (index) {
        if (index == _addConnectionIndex) {
          _runManageConnections();
        } else if (index >= 0 && index < _results.length) {
          widget.onSelect(_results[index].target);
        }
      },
      builder: (context, listController) {
        listController.clamp(0, _rowCount - 1);
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
                  return null;
                },
              ),
              ActivateListSelectionIntent:
                  CallbackAction<ActivateListSelectionIntent>(
                    onInvoke: (intent) {
                      _handleEnter();
                      return null;
                    },
                  ),
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Focus(
                  canRequestFocus: false,
                  onKeyEvent: _onSearchFieldKey,
                  child: _buildSearchField(),
                ),
                // Breathing room between the fading-underline filter and the
                // first row.
                SizedBox(height: context.theme.spacing.lg),
                Flexible(
                  // Always render the list — even with no matching targets the
                  // synthetic "+ Add a connection…" row (the final item) is
                  // present, so there is no separate empty state. The list runs
                  // to the bottom edge of the page; [ScrollEdgeFade] fades the
                  // top once scrolled and the bottom while rows remain below.
                  // Transparent (alpha-mask) mode because the page sits on the
                  // translucent/tinted scaffold frame — a solid-background fade
                  // would read as a card.
                  child: ScrollEdgeFade(
                    transparent: true,
                    child: ListView.builder(
                      controller: widget.scrollController,
                      shrinkWrap: true,
                      itemCount: _rowCount,
                      itemBuilder: (context, index) {
                        if (index == _addConnectionIndex) {
                          return _buildAddConnectionRow(context, index);
                        }
                        return _buildRow(
                          context,
                          _results[index],
                          index,
                          listController,
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The step-1 filter input: a borderless field with a fading underline that
  /// glows in the centre and dissolves into the page background at both ends.
  /// It is sized a calm step above the rows ([Typography.lg]) so it reads as
  /// the entry point rather than a constrained form field. The host supplies
  /// the horizontal page padding.
  Widget _buildSearchField() {
    final autofocus = widget.autofocusSearch && hasPhysicalKeyboard();
    const hint = 'Start with a person, group, or connection...';
    final typography = context.theme.typography;
    final colors = context.theme.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FTextField(
          // `_runSearch` reads `_controller.text` itself, so the control's
          // onChange (which delivers a TextEditingValue) just needs to fire it.
          control: .managed(
            controller: _controller,
            onChange: (_) => _onSearchChanged(),
          ),
          focusNode: _searchFocusNode,
          autofocus: autofocus,
          // Keep focus on the filter when the user clicks empty space on the
          // compose page. Flutter's text field unfocuses itself on any tap
          // outside its tap-region by default; overriding onTapOutside with a
          // no-op suppresses that so a stray click around the field doesn't
          // drop the user out of the filter. Focus still leaves via Escape or
          // by tapping another field/control.
          onTapOutside: (_) {},
          hint: hint,
          style: FTextFieldStyleDelta.delta(
            // Roomy vertical padding so the field reads as an open prompt
            // rather than a boxed input. No `minHeight` floor: the always-laid-
            // out clear-button suffix (below) sets a stable height and centres
            // the text, exactly as the app header search bar does.
            contentPadding: EdgeInsetsGeometryDelta.value(
              const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            ),
            // Transparent fill in EVERY state — the global text-field delta
            // (style/text_field.dart) fills the field with `editableBackground`
            // on focus; without this override the borderless prompt would grow
            // a focus background. The fading underline is the only focus cue.
            color: FVariantsValueDelta.delta([
              FVariantValueDeltaOperation.all(const Color(0x00000000)),
              FVariantValueDeltaOperation.exact(
                {FTextFieldVariantConstraint.focused},
                const Color(0x00000000),
              ),
            ]),
            // A calm step above the rows ([Typography.md], 15px) and the app
            // header search, so the prompt reads as the focal entry point.
            contentTextStyle: FVariantsDelta.delta([
              FVariantOperation.all(
                TextStyleDelta.delta(fontSize: typography.lg.fontSize),
              ),
            ]),
            hintTextStyle: FVariantsDelta.delta([
              FVariantOperation.all(
                TextStyleDelta.delta(fontSize: typography.lg.fontSize),
              ),
            ]),
            // Borderless: drop the box outline in every state — the fading
            // underline below is the only chrome. The focused override is
            // explicit because the app theme otherwise paints a focused accent
            // border that the `all` override does not replace.
            border: FVariantsValueDelta.delta([
              FVariantValueDeltaOperation.all(
                const OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.zero,
                ),
              ),
              FVariantValueDeltaOperation.exact(
                {FTextFieldVariantConstraint.focused},
                const OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.zero,
                ),
              ),
            ]),
          ),
          // Trailing clear "✕" inside the input. Rendered through the text
          // field's own clear-button chrome (`clearButtonStyle` +
          // `clearButtonPadding` + `icons.x`). Tapping it clears the controller
          // and re-runs the search so the full list returns (see
          // [_clearSearch]).
          //
          // The clear button is **always** laid out so the field takes its
          // stable height and vertically-centred text from it instead of a
          // `minHeight` floor. When the field is empty the same button is still
          // present and sized — it is just made invisible (`Opacity 0`) and
          // non-interactive (`IgnorePointer`), so the field height and text
          // centring never change as text comes and goes. The
          // [ValueListenableBuilder] rebuilds only this suffix subtree (not the
          // field's EditableText), so toggling it never tears down the editor
          // or drops focus.
          suffixBuilder: (context, style, states) {
            return ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, _) {
                final hasText = value.text.isNotEmpty;
                return Padding(
                  padding: style.clearButtonPadding,
                  child: IgnorePointer(
                    ignoring: !hasText,
                    child: Opacity(
                      opacity: hasText ? 1.0 : 0.0,
                      child: FButton.icon(
                        style: style.clearButtonStyle,
                        onPress: _clearSearch,
                        child: context.theme.icons.x(context),
                      ),
                    ),
                  ),
                );
              },
            );
          },
          onSubmit: (_) => _handleEnter(),
        ),
        // Fading underline: glows in the centre, dissolves into the page
        // background at both edges; neutral, brightening slightly on focus
        // (no accent tint).
        _FadingUnderline(
          focusNode: _searchFocusNode,
          color: colors.border,
          focusedColor: colors.foreground.withValues(alpha: 0.3),
        ),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context,
    ComposeTargetView view,
    int index,
    ListViewSelectorController listController,
  ) {
    final tile = _rowContent(context, view);
    return MouseRegion(
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
        onTap: () => widget.onSelect(view.target),
        child: _rowDecoration(
          context,
          highlighted: index == _highlightedIndex,
          child: tile,
        ),
      ),
    );
  }

  /// Row chrome shared by target rows and the add-connection row.
  ///
  /// A rounded hover/selection fill at the sidebar's tile radius
  /// ([tileBorderRadius], 6px) and no border. The highlight matches the
  /// activity feed's row hover level ([ColourScheme.editableBackground], the
  /// same `highlightColor` thread rows use) rather than the heavier `secondary`
  /// tint. The `sm` bottom margin gives a comfortable gap between rows so they
  /// read as distinct.
  Widget _rowDecoration(
    BuildContext context, {
    required bool highlighted,
    required Widget child,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: context.theme.spacing.sm),
      decoration: BoxDecoration(
        color: highlighted ? context.colour.editableBackground : null,
        borderRadius: tileBorderRadius,
      ),
      child: child,
    );
  }

  /// The synthetic, always-last "+ Add a connection…" row (tweak 7). It is not
  /// a [ComposeTarget] (never selectable as a compose target, untouched by the
  /// dedup) and tapping it opens [ManageConnections]. Rendered with a muted "+"
  /// affordance so it reads as an action rather than a target.
  Widget _buildAddConnectionRow(BuildContext context, int index) {
    final colors = context.theme.colors;
    final spacing = context.theme.spacing;
    // Match the target rows' leading slot exactly so the "+" lines up under the
    // rows' line-2 glyphs and the label starts at the same x as the rows above.
    //
    // The target rows' [_leadingGlyph] is wrapped in `leadingPadding`
    // (left: lg, right: 8) around a 16×16 image, with the label immediately
    // after — so the label's left edge sits at exactly `lg + 16 + 8`. We
    // reproduce that here: the same `leadingPadding` around a 16px plus glyph,
    // then the label immediately after — no extra outer horizontal padding that
    // would push the label right of the rows above.
    final leadingPadding = EdgeInsets.only(left: spacing.lg, right: 8);
    // Match the comfortable target-row density (see [_rowContent]).
    final double verticalPadding = spacing.md;
    final tile = Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: leadingPadding,
            child: SizedBox(
              width: 16,
              height: 16,
              child: Icon(
                PlotIcon.add,
                size: 16,
                color: colors.mutedForeground,
              ),
            ),
          ),
          Expanded(
            child: Text(
              'Add a connection…',
              overflow: TextOverflow.ellipsis,
              // Match the target rows' title size (ListTile items render at
              // typography.md); muted to read as a secondary action.
              style: context.theme.typography.md.copyWith(
                color: colors.mutedForeground,
              ),
            ),
          ),
        ],
      ),
    );
    return MouseRegion(
      onEnter: (_) {
        if (!_mouseHasMoved) return;
        setState(() => _highlightedIndex = index);
      },
      onExit: (_) {
        if (!_mouseHasMoved) return;
        setState(() => _highlightedIndex = -1);
      },
      onHover: (_) {
        if (!_mouseHasMoved) {
          setState(() {
            _mouseHasMoved = true;
            _highlightedIndex = index;
          });
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _runManageConnections,
        child: _rowDecoration(
          context,
          highlighted: index == _highlightedIndex,
          child: tile,
        ),
      ),
    );
  }

  /// Two-line row: line 1 = focus-tinted connection header; line 2 = leading
  /// glyph + people / channel / focus / twist content.
  ///
  /// Comfortable vertical padding (`spacing.md`) gives each row room to breathe
  /// so the two lines read as one distinct entry. The host supplies the
  /// horizontal page padding; the leading glyph provides the left gutter.
  Widget _rowContent(BuildContext context, ComposeTargetView view) {
    final isDark = context.read<ThemeBloc>().isDarkMode(context);
    final spacing = context.theme.spacing;
    final headerColor = context.colour.colours.fromTheme(
      view.headerColor,
      muted: true,
    );
    final leadingPadding = EdgeInsets.only(left: spacing.lg, right: 8);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(left: spacing.lg, bottom: 2),
            child: Text(
              view.header,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.theme.typography.xs.copyWith(
                color: headerColor,
                height: 1,
              ),
            ),
          ),
          _rowContentLine(context, view, isDark, leadingPadding),
        ],
      ),
    );
  }

  Widget _rowContentLine(
    BuildContext context,
    ComposeTargetView view,
    bool isDark,
    EdgeInsets leadingPadding,
  ) {
    final t = view.target;

    // The main row label (contact names / channel / twist name) reads as quiet
    // secondary text — muted rather than full-strength foreground so it doesn't
    // pull attention the way a primary title would.
    final labelStyle = context.theme.typography.md.copyWith(
      color: context.theme.colors.mutedForeground,
    );

    // Focus-note: focus icon + name in the focus colour (via FocusLabel),
    // replacing the leading logo.
    if (t.kind == ComposeTargetKind.note && view.focusPriority != null) {
      return Padding(
        padding: leadingPadding,
        child: FocusLabel(priority: view.focusPriority, muted: true),
      );
    }

    final leading = Padding(
      padding: leadingPadding,
      child: _leadingGlyph(context, view, isDark),
    );

    // People (Plot chat / connector DM): logo + avatars + names, hover tooltip.
    if (view.recipients.isNotEmpty) {
      final actors = <Actor>[
        for (final r in view.recipients)
          if (r.actorId != null && Actor.fromCache(r.actorId!) != null)
            Actor.fromCache(r.actorId!)!,
      ];
      final names = view.recipients
          .map(
            (r) => (r.showEmail && r.email != null)
                ? '${r.name} <${r.email}>'
                : r.name,
          )
          .join(', ');
      final content = Row(
        children: [
          leading,
          if (actors.isNotEmpty) ...[
            AvatarGroup(
              actors: actors,
              totalCount: view.recipients.length,
              // 20 (not the logo's 16): AvatarGroup draws a 1.2px ring, so the
              // visible circle is ~17.6 — a touch taller than the leading logo,
              // which reads as balanced rather than undersized.
              size: 20,
            ),
            SizedBox(width: context.theme.spacing.sm),
          ],
          Expanded(
            child: Text(
              names,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ),
        ],
      );
      return _withRecipientTooltip(context, view, content);
    }

    // Twist: logo + twist name.
    if (t.kind == ComposeTargetKind.twist) {
      return Row(
        children: [
          leading,
          Expanded(
            child: Text(
              t.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ),
        ],
      );
    }

    // Channel connector: logo + channel name.
    final channelName = t.channel?.title ?? t.label;
    return Row(
      children: [
        leading,
        Expanded(
          child: Text(
            channelName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: labelStyle,
          ),
        ),
      ],
    );
  }

  /// The 16×16 leading glyph for line 2, mirroring the old `_targetTile` logo
  /// resolution per kind (chat → Plot mark; connector → link-type logo;
  /// twist → connection logo). Focus-notes never reach here (handled inline).
  Widget _leadingGlyph(
    BuildContext context,
    ComposeTargetView view,
    bool isDark,
  ) {
    final t = view.target;
    switch (t.kind) {
      case ComposeTargetKind.note:
      case ComposeTargetKind.chat:
        return SvgPicture.asset('assets/plot-icon.svg', width: 16, height: 16);
      case ComposeTargetKind.connector:
        final lt = t.linkType;
        final logo = lt == null
            ? null
            : (isDark ? (lt.logoDark ?? lt.logo) : lt.logo);
        return logo == null
            ? const Icon(PlotIcon.link, size: 16)
            : LogoImage(
                url: logo,
                size: 16,
                fallback: const Icon(PlotIcon.link, size: 16),
              );
      case ComposeTargetKind.twist:
        final twist = t.connection;
        final logo = twist == null
            ? null
            : (isDark ? (twist.logoUrlDark ?? twist.logoUrl) : twist.logoUrl);
        return logo == null
            ? const Icon(PlotIcon.twist, size: 16)
            : LogoImage(
                url: logo,
                size: 16,
                fallback: const Icon(PlotIcon.twist, size: 16),
              );
    }
  }

  /// Wrap the people content in a tooltip listing every recipient as
  /// "Name — email" (full names + addresses on hover).
  Widget _withRecipientTooltip(
    BuildContext context,
    ComposeTargetView view,
    Widget child,
  ) {
    final lines = view.recipients
        .map((r) {
          final email = r.email;
          return (email != null && email.isNotEmpty && email != r.name)
              ? '${r.name} — $email'
              : r.name;
        })
        .join('\n');
    if (lines.isEmpty) return child;
    return FTooltip(
      tipBuilder: (context, controller) => Text(lines),
      child: child,
    );
  }
}

/// A ~1.5px horizontal hairline that glows in the centre and dissolves into the
/// page background at both ends (a gradient from transparent → [color] →
/// transparent). The sole chrome under the step-1 filter input. It brightens
/// from [color] to [focusedColor] when [focusNode] gains focus, animated so the
/// transition reads as calm. The colour stays neutral — no accent tint —
/// consistent with the picker's deliberately un-tinted focus state.
class _FadingUnderline extends StatelessWidget {
  const _FadingUnderline({
    required this.focusNode,
    required this.color,
    required this.focusedColor,
  });

  final FocusNode focusNode;
  final Color color;
  final Color focusedColor;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: focusNode,
      builder: (context, _) {
        final line = focusNode.hasFocus ? focusedColor : color;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: 1.5,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                line.withValues(alpha: 0),
                line,
                line,
                line.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.18, 0.82, 1.0],
            ),
          ),
        );
      },
    );
  }
}

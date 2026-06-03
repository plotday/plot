import 'dart:async';

// OutlineInputBorder is needed to override the inline filter's focused-state
// border colour (tweak 3). Imported with `show` per the established pattern in
// widget/text_field.dart and widget/date_input.dart.
import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/command/command.dart'
    show BuildContextCommandExtension, ManageConnections;
import 'package:plot/state/compose_targets.dart';
import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';
// ListViewSelector + its controller; the MoveListSelectionIntent /
// ActivateListSelectionIntent classes are also exported by widget.dart (via
// infinite_list.dart), so hide the duplicates here and use the barrel's.
import 'package:plot/widget/list_view_selector.dart'
    show ListViewSelector, ListViewSelectorController;
import 'package:plot/widget/widget.dart';

/// The step-1 **target picker** body: a search box over the
/// [ComposeTargetsBloc] ranked list with keyboard navigation identical to the
/// connection [SelectModal] (↑/↓ highlight, Enter select, type-to-filter).
///
/// Built on the same low-level primitives the modal uses ([ListViewSelector] +
/// [Shortcuts]/[Actions]) rather than the [Modal]-coupled `_SelectModal`, so it
/// can be mounted **both** inline on the compose page (step 1) and inside a
/// [Modal] (step-2 re-open) without depending on `Modal.pop`/`ModalProvider`.
///
/// Selection is reported via [onSelect]; the host decides what to do (apply the
/// target and advance to step 2, or re-apply and pop the modal). Search routes
/// through [ComposeTargetsBloc.search]; the base list comes from the bloc's
/// state (populate it via [ComposeTargetsBloc.refresh] before opening).
class TargetPickerList extends StatefulWidget {
  const TargetPickerList({
    super.key,
    required this.onSelect,
    required this.scrollController,
    this.listFocusNode,
    this.searchController,
    this.searchFocusNode,
    this.inline = false,
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

  /// Focus node for the inline search field. Optional — a local one is created
  /// when null. The host can supply (and retain) one so it can re-focus the
  /// field when it resets an already-open page back to step 1 (see
  /// [NewThreadPageState._resetToFreshStart]). Only used on the inline path;
  /// the modal's ghost field manages its own focus.
  final FocusNode? searchFocusNode;

  /// When true the search field is styled to sit on the compose page (no
  /// modal back-button row / close-button reservation). When false the field
  /// renders as a modal header.
  final bool inline;

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

  /// Results currently displayed. Seeded from the bloc's base list and
  /// replaced by [ComposeTargetsBloc.search] as the user types.
  List<ComposeTarget> _results = const [];
  int _highlightedIndex = 0;
  bool _mouseHasMoved = false;
  bool _isDisposed = false;
  int _requestId = 0;

  /// Trimmed search text whose results are displayed. Used to flush an
  /// in-flight search on Enter so we activate against fresh results.
  String _appliedSearch = '';
  Future<void>? _lastSearch;
  bool _enterHandled = false;

  @override
  void initState() {
    super.initState();
    _results = context.read<ComposeTargetsBloc>().state.targets;
  }

  /// Re-seed the displayed results from the bloc's freshly-emitted base list.
  ///
  /// Only fires on the empty-query path — when the user has typed a search,
  /// [_runSearch] owns [_results] and a base-list re-emit (e.g. from
  /// [ComposeTargetsBloc.prependToCache] after a thread is created) must not
  /// clobber the active filter/synthesis. On a fresh open the base list is
  /// usually still empty when this widget mounts (the page fires
  /// [ComposeTargetsBloc.refresh] fire-and-forget), so this listener is what
  /// surfaces Note/Chat (and the rest) once `refresh()` resolves.
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
    if (_ownsFocusNode) _listFocusNode.dispose();
    if (_ownsController) _controller.dispose();
    if (_ownsSearchFocusNode) _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _runSearch() {
    final query = _controller.text;
    final requestId = ++_requestId;
    final future = context.read<ComposeTargetsBloc>().search(query).then((
      results,
    ) {
      if (_isDisposed || requestId != _requestId) return;
      setState(() {
        _results = results;
        _appliedSearch = query.trim();
        // Clamp against [_rowCount] so the add-connection row stays reachable
        // (and becomes the sole, highlightable row when nothing matches).
        _highlightedIndex = _highlightedIndex.clamp(0, _rowCount - 1);
      });
    }).catchError((Object e, StackTrace s) {
      Tracker.captureException(e, s);
    });
    return _lastSearch = future;
  }

  /// Awaits the in-flight search (and any successor) so Enter acts on results
  /// matching the fully-typed text.
  Future<void> _flushPendingSearch() async {
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
      _highlightedIndex = (_highlightedIndex + offset).clamp(
        0,
        _rowCount - 1,
      );
    });
    _scrollToIndex(_highlightedIndex);
  }

  void _scrollToIndex(int index) {
    if (!widget.scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.scrollController.hasClients) return;
      const estimatedItemHeight = 50.0;
      if (index == 0) {
        widget.scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        return;
      }
      final estimatedOffset = index * estimatedItemHeight;
      final viewportHeight = widget.scrollController.position.viewportDimension;
      final currentScroll = widget.scrollController.offset;
      final maxScroll = widget.scrollController.position.maxScrollExtent;
      if (estimatedOffset < currentScroll) {
        widget.scrollController.animateTo(
          estimatedOffset,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else if (estimatedOffset + (estimatedItemHeight * 2) >
          currentScroll + viewportHeight) {
        widget.scrollController.animateTo(
          (estimatedOffset + (estimatedItemHeight * 2) - viewportHeight).clamp(
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

    if (_controller.text.trim() != _appliedSearch || _lastSearch != null) {
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
    widget.onSelect(_results[_highlightedIndex]);
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

  /// Clears the inline filter (tweak 2): empties the controller and re-runs
  /// the search so the full base list returns, keeping focus on the field so
  /// the user can keep typing.
  void _clearSearch() {
    _controller.clear();
    _runSearch();
    if (widget.inline) _searchFocusNode.requestFocus();
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
      estimatedItemHeight: 50.0,
      onActivate: (index) {
        if (index == _addConnectionIndex) {
          _runManageConnections();
        } else if (index >= 0 && index < _results.length) {
          widget.onSelect(_results[index]);
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
                // Inline only: breathing room between the header-style search
                // field and the first row. The modal reproduces the old
                // connection picker exactly, which had no gap here.
                if (widget.inline)
                  SizedBox(height: context.theme.spacing.lg),
                Flexible(
                  // Always render the list — even with no matching targets the
                  // synthetic "+ Add a connection…" row (the final item) is
                  // present, so there is no separate empty state.
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
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSearchField() {
    final autofocus = widget.autofocusSearch && hasPhysicalKeyboard();
    const hint = 'Pick a connection or type a name...';

    // Inline (step 1 on the compose page): match the app header's search field
    // (see [unified_header.dart] `_buildSearchField`) exactly — same compact
    // contentPadding (h8/v2) and the same theme-driven text style (the global
    // text-field delta in style/text_field.dart sizes content/hint at
    // typography.md), so the two fields render identically in size. The host
    // supplies the horizontal page padding, so this field needs none of its
    // own. Differences from the header: a focused border that stays neutral
    // (tweak 3) and a trailing clear button (tweak 2).
    if (widget.inline) {
      final typography = context.theme.typography;
      final colors = context.theme.colors;
      final borderRadius = context.theme.style.borderRadius;
      final borderWidth = context.theme.style.borderWidth;
      return FTextField(
        // `_runSearch` reads `_controller.text` itself, so the control's
        // onChange (which delivers a TextEditingValue) just needs to fire it.
        control: .managed(
          controller: _controller,
          onChange: (_) => _runSearch(),
        ),
        focusNode: _searchFocusNode,
        autofocus: autofocus,
        hint: hint,
        style: FTextFieldStyleDelta.delta(
          // No `minHeight` floor: the header `Search…` bar's stable ~36 height
          // (and its vertically-centred text) come from its always-present
          // trailing ghost `Button.icon`, not a height constraint. forui's
          // InputDecorator only centres the content vertically when a suffix of
          // that height is present; a `minHeight` floor instead grows the box
          // but leaves the placeholder/text top-aligned. We reproduce the
          // header by giving this field a permanent button-sized suffix (see
          // `suffixBuilder` below — the clear `✕` is always laid out, merely
          // faded/disabled when empty), so the field's resting height and text
          // centring match the header and never jump as the clear button
          // shows/hides.
          contentPadding: EdgeInsetsGeometryDelta.value(
            const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          ),
          // Match the header's text size explicitly (typography.md), so the
          // inline filter never drifts from the header even if the field's
          // local style is changed later.
          contentTextStyle: FVariantsDelta.delta([
            FVariantOperation.all(
              TextStyleDelta.delta(fontSize: typography.md.fontSize),
            ),
          ]),
          hintTextStyle: FVariantsDelta.delta([
            FVariantOperation.all(
              TextStyleDelta.delta(fontSize: typography.md.fontSize),
            ),
          ]),
          // Neutral focused border (tweak 3): forui/the app theme paint the
          // focused border with the accent colour by default; override the
          // focused variant back to the resting border colour so focusing the
          // filter doesn't tint it.
          border: FVariantsValueDelta.delta([
            FVariantValueDeltaOperation.exact(
              {FTextFieldVariantConstraint.focused},
              OutlineInputBorder(
                borderSide: BorderSide(
                  color: colors.border,
                  width: borderWidth,
                ),
                borderRadius: borderRadius.md,
              ),
            ),
          ]),
        ),
        // Trailing clear "✕" inside the input (tweak 2). Rendered through the
        // text field's own clear-button chrome (`clearButtonStyle` +
        // `clearButtonPadding` + `icons.x`) so it matches the search-bar look.
        // Tapping it clears the controller and re-runs the search so the full
        // list returns (see [_clearSearch]).
        //
        // The clear button is **always** laid out (exactly like the header
        // search bar's unconditional close-search `Button.icon`) so the field
        // takes its stable ~36 height and vertically-centred text from it
        // instead of a `minHeight` floor. When the field is empty the same
        // button is still present and sized — it is just made invisible
        // (`Opacity 0`) and non-interactive (`IgnorePointer`), so the suffix's
        // footprint, and therefore the field height and text centring, never
        // change as text comes and goes. The [ValueListenableBuilder] rebuilds
        // only this suffix subtree (not the field's EditableText), so toggling
        // `opacity`/`ignoring` as the user types never tears down the editor
        // and focus is preserved.
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
      );
    }

    // Modal (step-2 re-open): reproduce the old connection [SelectModal]'s
    // search field exactly — a clean, borderless ghost TextField with no
    // leading magnifier (the modal only shows the magnifier when it has no
    // prompt; here the placeholder *is* the prompt). The modal wraps its field
    // in the standard widget padding.
    return Padding(
      padding: context.theme.spacing.padding,
      child: TextField(
        maxLines: 1,
        style: TextFieldStyle.ghost,
        controller: _controller,
        autofocus: autofocus,
        label: hint,
        onChanged: (_) => _runSearch(),
        onSubmitted: (_) => _handleEnter(),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    ComposeTarget target,
    int index,
    ListViewSelectorController listController,
  ) {
    final tile = _targetTile(context, target);
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
        onTap: () => widget.onSelect(target),
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
  /// Inline (tweak 5): each row matches the left-sidebar focus rows — a
  /// rounded hover/selection fill at the sidebar's tile radius
  /// ([tileBorderRadius], 6px; see `PrioritiesList` `itemBorderRadius` and
  /// `PriorityWidget.borderRadius`) and no border. Modal: flat rows (a bare
  /// highlight fill, no border/radius) exactly as the old connection picker
  /// rendered them.
  Widget _rowDecoration(
    BuildContext context, {
    required bool highlighted,
    required Widget child,
  }) {
    final colors = context.theme.colors;
    if (!widget.inline) {
      return Container(
        decoration: BoxDecoration(
          color: highlighted ? colors.secondary : null,
        ),
        child: child,
      );
    }
    return Container(
      margin: EdgeInsets.only(bottom: context.theme.spacing.xs),
      decoration: BoxDecoration(
        color: highlighted ? colors.secondary : null,
        borderRadius: tileBorderRadius,
      ),
      child: child,
    );
  }

  /// The synthetic, always-last "+ Add a connection…" row (tweak 7). Present
  /// in both inline and modal contexts; it is not a [ComposeTarget] (never
  /// selectable as a compose target, untouched by the dedup) and tapping it
  /// opens [ManageConnections]. Rendered with a muted "+" affordance so it
  /// reads as an action rather than a target.
  Widget _buildAddConnectionRow(BuildContext context, int index) {
    final colors = context.theme.colors;
    final spacing = context.theme.spacing;
    // Match the target rows' leading slot exactly so the "+" lines up under the
    // rows' logos and the label starts at the same x as "Chat"/"Note".
    //
    // In [_targetTile] the logo is the ListTile's leading widget, wrapped in
    // `leadingPadding` (left: lg, right: 8) around a 16×16 image. The ListTile
    // adds no further horizontal inset to a leading widget (its outer
    // content-padding only drives the empty leading/trailing gutters, which are
    // zero-width whenever a leading widget is present) and forces the title's
    // own left padding to 0, so the title's left edge sits at exactly
    // `lg + 16 + 8`. We reproduce that here: the same `leadingPadding` around a
    // 16px plus glyph, then the label immediately after — no extra outer
    // horizontal padding that would push the label right of the rows above.
    //
    // Vertical inset mirrors the target tiles per context: inline tiles inherit
    // the default ListTile content padding (`paddingSm` → vertical `sm`); modal
    // tiles use the compact `vertical: xs`.
    final leadingPadding = EdgeInsets.only(left: spacing.lg, right: 8);
    final double verticalPadding = widget.inline ? spacing.sm : spacing.xs;
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

  /// Renders a [ComposeTarget] as a [ListTile] mirroring the connection
  /// picker's row chrome (logo + label).
  ///
  /// Row density differs by context. **Modal** (`inline: false`, the step-2
  /// re-open) uses a compact vertical padding so the list reads as densely as
  /// the old connection [SelectModal]'s rows. **Inline** (`inline: true`, step
  /// 1 on the compose page) keeps the default [ListTile] padding. Horizontal
  /// inset stays at `lg`; the leading logo provides the left gutter when
  /// present.
  ListTile _targetTile(BuildContext context, ComposeTarget target) {
    final isDark = context.read<ThemeBloc>().isDarkMode(context);
    // Modal only: compact rows. Inline passes null to inherit the default
    // ListTile content padding.
    final EdgeInsets? padding = widget.inline
        ? null
        : EdgeInsets.symmetric(
            horizontal: context.theme.spacing.lg,
            vertical: context.theme.spacing.xs,
          );
    final leadingPadding = EdgeInsets.only(
      left: context.theme.spacing.lg,
      right: 8,
    );
    switch (target.kind) {
      case ComposeTargetKind.note:
      case ComposeTargetKind.chat:
        return ListTile(
          padding: padding,
          leadingBuilder: (_, _) => Builder(
            builder: (context) => Padding(
              padding: leadingPadding,
              child: SvgPicture.asset(
                'assets/plot-icon.svg',
                width: 16,
                height: 16,
              ),
            ),
          ),
          title: target.label,
        );
      case ComposeTargetKind.connector:
        final lt = target.linkType;
        final logo = lt == null
            ? null
            : (isDark ? (lt.logoDark ?? lt.logo) : lt.logo);
        return ListTile(
          padding: padding,
          leadingBuilder: logo != null
              ? (_, _) => Builder(
                    builder: (context) => Padding(
                      padding: leadingPadding,
                      child: LogoImage(
                        url: logo,
                        size: 16,
                        fallback: const Icon(PlotIcon.link, size: 16),
                      ),
                    ),
                  )
              : null,
          icon: logo == null ? PlotIcon.link : null,
          title: target.label,
        );
      case ComposeTargetKind.twist:
        final twist = target.connection;
        final logo = twist == null
            ? null
            : (isDark ? (twist.logoUrlDark ?? twist.logoUrl) : twist.logoUrl);
        return ListTile(
          padding: padding,
          leadingBuilder: logo != null
              ? (_, _) => Builder(
                    builder: (context) => Padding(
                      padding: leadingPadding,
                      child: LogoImage(
                        url: logo,
                        size: 16,
                        fallback: const Icon(PlotIcon.twist, size: 16),
                      ),
                    ),
                  )
              : null,
          icon: logo == null ? PlotIcon.twist : null,
          title: target.label,
        );
    }
  }
}

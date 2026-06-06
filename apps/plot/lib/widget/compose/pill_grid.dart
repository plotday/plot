import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/layout.dart' show tileBorderRadius;
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/compose/compose_pill.dart';
import 'package:plot/widget/compose/pill_grid_geometry.dart';

// ─── Data model ──────────────────────────────────────────────────────────────

/// A single row item in a [PillGrid]: its data and activation callback.
class PillGridItem {
  PillGridItem({
    required this.data,
    required this.onActivate,
  });

  final ComposePillData data;
  final VoidCallback onActivate;
}

/// A labeled group of [PillGridItem]s rendered as a section inside [PillGrid].
class PillGridSection {
  PillGridSection({required this.header, required this.items});

  /// A header widget — e.g. a "Channels" label — rendered above the pill row.
  final Widget header;
  final List<PillGridItem> items;
}

// ─── Widget ──────────────────────────────────────────────────────────────────

/// A scrollable list of single-line rows ([ComposePill] content wrapped in row
/// chrome) organised into [PillGridSection]s with geometry-aware arrow-key
/// navigation.
///
/// The parent owns the [scrollController] and [gridFocusNode]. Arrow-key
/// navigation (←/→ reading-order, ↑/↓ visual rows) is driven by
/// [PillGridGeometry] which operates on measured on-screen [Rect]s. Moving up
/// past the top row calls [onMoveToSearch] so the host can return focus to the
/// search field.
///
/// The state is kept public ([PillGridState]) so the parent can call
/// [PillGridState.focusFirst] via a [GlobalKey<PillGridState>] when the user
/// presses ↓ in the search field.
class PillGrid extends StatefulWidget {
  const PillGrid({
    super.key,
    required this.sections,
    required this.scrollController,
    required this.gridFocusNode,
    required this.onMoveToSearch,
  });

  final List<PillGridSection> sections;
  final ScrollController scrollController;
  final FocusNode gridFocusNode;

  /// Called when ↑ is pressed from the top row of pills — the host should
  /// return keyboard focus to the search bar.
  final VoidCallback onMoveToSearch;

  @override
  PillGridState createState() => PillGridState();
}

class PillGridState extends State<PillGrid> with WidgetsBindingObserver {
  /// Flat ordered list of all items (section order, then item order).
  late List<PillGridItem> _flat;

  /// One [GlobalKey] per flat item, used to measure each pill's on-screen rect.
  late List<GlobalKey> _keys;

  /// Key on the [Column] that is the direct child of [SingleChildScrollView],
  /// used as the coordinate-space anchor for [_measure] so that rects are in
  /// content-space (independent of the current scroll offset).
  final GlobalKey _contentKey = GlobalKey();

  /// Most-recently-measured rects in the grid's own coordinate space.
  /// Parallel to [_flat] / [_keys]. A zero rect is stored for any pill whose
  /// context isn't laid out yet.
  late List<Rect> _rects;

  /// Index of the currently focused pill (keyboard or mouse hover).
  int _focused = 0;

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _rebuild();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(PillGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sections != widget.sections) {
      _rebuild();
      // Clamp focus into the new range.
      if (_flat.isNotEmpty) {
        _focused = _focused.clamp(0, _flat.length - 1);
      } else {
        _focused = 0;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-measure when the viewport metrics change (e.g. window resize).
  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  // ─── Public API ────────────────────────────────────────────────────────────

  /// Focus the first pill and request keyboard focus for [widget.gridFocusNode].
  /// Called by the parent (via [GlobalKey<PillGridState>]) when the user presses
  /// ↓ in the search field.
  void focusFirst() {
    if (_flat.isEmpty) return;
    setState(() => _focused = 0);
    widget.gridFocusNode.requestFocus();
    _scrollIntoView(0);
  }

  // ─── Internal helpers ──────────────────────────────────────────────────────

  /// Rebuild [_flat], [_keys], and [_rects] from [widget.sections].
  void _rebuild() {
    _flat = [
      for (final section in widget.sections) ...section.items,
    ];
    _keys = List.generate(_flat.length, (_) => GlobalKey());
    _rects = List.filled(_flat.length, Rect.zero);
  }

  /// Measure every pill's rect in content-space (relative to the scroll
  /// content column, not the viewport) so that [_scrollIntoView] can treat
  /// [Rect.top]/[Rect.bottom] directly as content offsets.
  void _measure() {
    if (!mounted) return;
    if (_flat.isEmpty) return;

    final contentBox =
        _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox == null || !contentBox.hasSize) return;

    final newRects = List<Rect>.filled(_flat.length, Rect.zero);
    for (var i = 0; i < _keys.length; i++) {
      final ctx = _keys[i].currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final topLeft = contentBox.globalToLocal(box.localToGlobal(Offset.zero));
      newRects[i] = topLeft & box.size;
    }

    // Only rebuild if something changed to avoid unnecessary setState calls.
    var changed = false;
    for (var i = 0; i < newRects.length; i++) {
      if (newRects[i] != _rects[i]) {
        changed = true;
        break;
      }
    }
    if (changed && mounted) {
      setState(() => _rects = newRects);
    }
  }

  void _setFocus(int i) {
    if (_flat.isEmpty) return;
    setState(() => _focused = i.clamp(0, _flat.length - 1));
  }

  /// Scroll [_rects[i]] into view. Rects are in content-space so
  /// [Rect.top]/[Rect.bottom] are used directly as scroll offsets, compared
  /// against the current viewport window ([offset] … [offset + viewportDimension]).
  void _scrollIntoView(int i) {
    if (!widget.scrollController.hasClients) return;
    if (i < 0 || i >= _rects.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.scrollController.hasClients) return;
      if (i < 0 || i >= _rects.length) return;
      final r = _rects[i];
      if (r == Rect.zero) return;

      final pos = widget.scrollController.position;
      final viewportTop = widget.scrollController.offset;
      final viewportBottom = viewportTop + pos.viewportDimension;
      const margin = 8.0;

      double? target;
      if (r.top - margin < viewportTop) {
        target = r.top - margin;
      } else if (r.bottom + margin > viewportBottom) {
        target = r.bottom + margin - pos.viewportDimension;
      }
      if (target == null) return;
      widget.scrollController.animateTo(
        target.clamp(0.0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_flat.isEmpty) return KeyEventResult.ignored;

    final g = PillGridGeometry(_rects);

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      final n = g.horizontal(_focused, -1);
      _setFocus(n);
      _scrollIntoView(n);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      final n = g.horizontal(_focused, 1);
      _setFocus(n);
      _scrollIntoView(n);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      final n = g.vertical(_focused, 1);
      _setFocus(n);
      _scrollIntoView(n);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      final n = g.vertical(_focused, -1);
      if (n == PillGridGeometry.toSearchBar) {
        widget.onMoveToSearch();
      } else {
        _setFocus(n);
        _scrollIntoView(n);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_focused >= 0 && _focused < _flat.length) {
        _flat[_focused].onActivate();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final spacing = context.theme.spacing;

    // Build flat-index-to-row mapping as we iterate sections.
    int flatIndex = 0;
    final sectionWidgets = <Widget>[];

    for (final section in widget.sections) {
      sectionWidgets.add(section.header);
      sectionWidgets.add(SizedBox(height: spacing.sm));

      for (final item in section.items) {
        final index = flatIndex;
        sectionWidgets.add(
          KeyedSubtree(
            key: _keys[index],
            child: MouseRegion(
              onEnter: (_) => _setFocus(index),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: item.onActivate,
                child: _rowChrome(
                  context,
                  focused: index == _focused,
                  child: ComposePill(data: item.data),
                ),
              ),
            ),
          ),
        );
        flatIndex++;
      }

      // Generous gap below each section so the groups read as distinct.
      sectionWidgets.add(SizedBox(height: spacing.xl));
    }

    return Focus(
      focusNode: widget.gridFocusNode,
      onKeyEvent: _onKey,
      child: SingleChildScrollView(
        controller: widget.scrollController,
        child: Column(
          key: _contentKey,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: sectionWidgets,
        ),
      ),
    );
  }

  /// Row chrome shared by every grid item: a full-width hit area with a rounded
  /// hover / selection fill (no border) at the sidebar tile radius. The
  /// highlight matches the thread list's row hover level
  /// ([ColourSchemeData.editableBackground]); the keyboard-selected and
  /// mouse-hovered states share the same fill.
  Widget _rowChrome(
    BuildContext context, {
    required bool focused,
    required Widget child,
  }) {
    final spacing = context.theme.spacing;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.sm,
        vertical: spacing.sm,
      ),
      decoration: BoxDecoration(
        color: focused ? context.colour.editableBackground : null,
        borderRadius: tileBorderRadius,
      ),
      child: child,
    );
  }
}

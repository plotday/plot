import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/layout.dart' show tileBorderRadius;
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/compose/compose_pill.dart';

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
/// chrome) organised into [PillGridSection]s with a keyboard-driven highlight.
///
/// Keyboard focus never moves into the grid — it stays on the host's search
/// field at all times (mirroring the select modal). The host drives the highlight
/// by calling [PillGridState.moveHighlight] (±1 row) and
/// [PillGridState.activateHighlighted] (Enter) through a
/// [GlobalKey<PillGridState>] as the user presses ↑/↓/Enter in the search
/// field. The first row is highlighted at rest, so the first ↓ moves to the
/// second row; ↑ on the first row is a no-op (the first row stays highlighted,
/// and the filter keeps focus). Mouse hover also updates the highlight.
///
/// The parent owns the [scrollController]. Scroll-into-view uses each row's
/// measured on-screen [Rect] (captured in the scroll content's coordinate
/// space) so the highlighted row is kept visible as it moves.
class PillGrid extends StatefulWidget {
  const PillGrid({
    super.key,
    required this.sections,
    required this.scrollController,
  });

  final List<PillGridSection> sections;
  final ScrollController scrollController;

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

  /// Index of the currently highlighted row (keyboard or mouse hover). The
  /// first row is highlighted at rest.
  int _highlighted = 0;

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
      // A new result set (e.g. the filter text changed) re-highlights the first
      // row so the top match is preselected, matching the select modal.
      _highlighted = 0;
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

  /// Moves the highlight by [delta] rows (+1 down, −1 up), clamped to the list
  /// bounds. The grid never requests keyboard focus — the search field above
  /// keeps it — so the user can keep typing to refine the filter. ↑ on the
  /// first row is a no-op (the first row stays highlighted), mirroring the
  /// select modal. Called by the host (via [GlobalKey<PillGridState>]) when the
  /// user presses ↑/↓ in the search field.
  void moveHighlight(int delta) {
    if (_flat.isEmpty) return;
    final next = (_highlighted + delta).clamp(0, _flat.length - 1);
    if (next == _highlighted) return;
    setState(() => _highlighted = next);
    _scrollIntoView(next);
  }

  /// Activates the currently-highlighted row. Called by the host when the user
  /// presses Enter in the search field. No-op when the list is empty.
  void activateHighlighted() {
    if (_highlighted < 0 || _highlighted >= _flat.length) return;
    _flat[_highlighted].onActivate();
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

  void _setHighlight(int i) {
    if (_flat.isEmpty) return;
    setState(() => _highlighted = i.clamp(0, _flat.length - 1));
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

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final spacing = context.theme.spacing;

    // Build flat-index-to-row mapping as we iterate sections.
    int flatIndex = 0;
    final sectionWidgets = <Widget>[];

    for (final section in widget.sections) {
      // Indent each section header by the row chrome's horizontal padding so
      // its left edge lines up with the item content (the leading icons) below.
      sectionWidgets.add(
        Padding(
          padding: EdgeInsets.only(left: spacing.sm),
          child: section.header,
        ),
      );
      sectionWidgets.add(SizedBox(height: spacing.sm));

      for (final item in section.items) {
        final index = flatIndex;
        sectionWidgets.add(
          KeyedSubtree(
            key: _keys[index],
            child: MouseRegion(
              onEnter: (_) => _setHighlight(index),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: item.onActivate,
                child: _rowChrome(
                  context,
                  highlighted: index == _highlighted,
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

    return SingleChildScrollView(
      controller: widget.scrollController,
      child: Column(
        key: _contentKey,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: sectionWidgets,
      ),
    );
  }

  /// Row chrome shared by every grid item: a full-width hit area with a rounded
  /// hover / highlight fill (no border) at the sidebar tile radius. The
  /// highlight matches the thread list's row hover level
  /// ([ColourSchemeData.editableBackground]); the keyboard-highlighted and
  /// mouse-hovered states share the same fill.
  Widget _rowChrome(
    BuildContext context, {
    required bool highlighted,
    required Widget child,
  }) {
    final spacing = context.theme.spacing;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.sm,
        vertical: spacing.sm,
      ),
      decoration: BoxDecoration(
        color: highlighted ? context.colour.editableBackground : null,
        borderRadius: tileBorderRadius,
        // A light selection ring. The border width is a constant 1px in both
        // states (transparent when not highlighted), so moving the selection
        // only changes the colour and never reflows the row content.
        border: Border.all(
          color: highlighted
              ? context.colour.border
              : const Color(0x00000000),
          width: 1,
        ),
      ),
      // Reserve a uniform content height (the widest leading glyph) so the
      // centred name sits at the same vertical position in every row — rows
      // with a short 16px logo/focus glyph would otherwise collapse to the
      // text height and render the name higher than the 24px avatar rows.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: composePillGutter),
        child: child,
      ),
    );
  }
}

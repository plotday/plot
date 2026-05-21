import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/state/note_viewer.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/util/profile_preferences.dart';
import 'note_viewer.dart';
import 'header.dart';
import 'unified_header.dart';

/// Outer inset around the squircle panel cards in multi-panel mode (window
/// edges and bottom). The header has no inset above the squircles so they
/// sit flush against the bottom of the per-column unified header.
const double _outerInset = 14.0;

/// Half of the gap between adjacent squircles that don't share one shape
/// (e.g. left sidebar squircle vs. main-panel squircle). Split evenly across
/// the FResizable region boundary so the boundary — and its drag handle —
/// lands at the visual center of the gap.
const double _halfGap = 7.0;

/// Corner radius for the squircle panel cards.
const double _panelRadius = 14.0;

/// Drop shadow used under a squircle panel card. Stronger in dark mode (the
/// card is darker than the frame, so a softer/longer shadow gives depth
/// without halo); in light mode a quieter shadow keeps the card from feeling
/// heavy against the bright surround.
BoxShadow _squircleShadow(BuildContext context) {
  final isDark = context.colour.brightness == Brightness.dark;
  return isDark
      ? BoxShadow(
          color: const Color(0xFF000000).withValues(alpha: 0.32),
          blurRadius: 16,
          offset: const Offset(0, 4),
          spreadRadius: -2,
        )
      : BoxShadow(
          color: const Color(0xFF000000).withValues(alpha: 0.06),
          blurRadius: 10,
          offset: const Offset(0, 3),
          spreadRadius: -1,
        );
}

/// Hairline border color for a squircle panel card (theme border tone
/// pulled to ~60% opacity so it reads as a refined hairline rather than a
/// hard outline).
Color _squircleBorderColor(BuildContext context) {
  final base = context.theme.colors.border;
  return base.withValues(alpha: base.a * 0.6);
}

/// FResizableRegionData asserts `extent.min < extent.max`, where each
/// region's `extent.max = total - sum(other regions' minExtent)`. With two
/// regions that boils down to requiring `minA + minB < total`. When the
/// container is exactly tight (e.g. totalWidth == middlePanelMin +
/// rightPanelMin), naively clamping each min to its initial extent produces
/// minA + minB == total and the assertion fires. Shrink the mins
/// proportionally until they sum to total - 1px, leaving room for the
/// invariant. Each min is also clamped to (0, initial] so it stays positive
/// and never exceeds the region's initial extent.
(double, double) _resizableMinExtents(
  double desiredMinA,
  double desiredMinB,
  double initialA,
  double initialB,
  double total,
) {
  const slack = 1.0;
  final cappedA = math.min(desiredMinA, initialA);
  final cappedB = math.min(desiredMinB, initialB);
  final budget = math.max(0.0, total - slack);
  final sum = cappedA + cappedB;
  if (sum <= budget) {
    return (math.max(1.0, cappedA), math.max(1.0, cappedB));
  }
  final scale = sum > 0 ? budget / sum : 0.0;
  return (math.max(1.0, cappedA * scale), math.max(1.0, cappedB * scale));
}

class ResizablePanelLayout extends StatefulWidget {
  const ResizablePanelLayout({
    required this.left,
    this.leftTop,
    required this.middle,
    required this.child,
    super.key,
  });

  /// Left panel (bottom of the vertical split when [leftTop] is provided).
  final Widget left;

  /// Optional top section of the left panel. When provided, the left panel
  /// is split vertically with [leftTop] on top and [left] on the bottom,
  /// separated by a draggable horizontal divider whose position is
  /// persisted across sessions.
  final Widget? leftTop;

  /// Middle panel when all three are shown.
  /// When only two are shown, child is in the middle
  final Widget middle;

  /// Always shows the child route.
  final Widget child;

  @override
  State<ResizablePanelLayout> createState() => _ResizablePanelLayoutState();
}

class _ResizablePanelLayoutState extends State<ResizablePanelLayout> {
  double _leftPanelWidth = 280.0;
  double _middlePanelRatio = 0.5;
  late final Future<void> _loadPreferencesFuture;

  /// Key for the right (thread) panel wrap. Used to find its left edge so
  /// the note-viewer overlay can cover everything to its left in
  /// multi-panel mode.
  final GlobalKey _rightPanelKey = GlobalKey();

  /// Key on the panel-layout root so we can translate the right panel's
  /// global position into a layout-local offset.
  final GlobalKey _selfKey = GlobalKey();

  /// Right panel's left edge in layout-local coordinates, or null if not
  /// yet measured. Updated after each frame.
  final ValueNotifier<double?> _rightPanelLeft = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _loadPreferencesFuture = _loadFromPreferences();
  }

  @override
  void dispose() {
    _rightPanelLeft.dispose();
    super.dispose();
  }

  void _scheduleMeasureRightPanel() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final selfBox = _selfKey.currentContext?.findRenderObject();
      final rightBox = _rightPanelKey.currentContext?.findRenderObject();
      if (selfBox is! RenderBox || rightBox is! RenderBox) {
        if (_rightPanelLeft.value != null) _rightPanelLeft.value = null;
        return;
      }
      if (!selfBox.attached || !rightBox.attached) return;
      final offset = rightBox.localToGlobal(Offset.zero, ancestor: selfBox);
      if (offset.dx != _rightPanelLeft.value) {
        _rightPanelLeft.value = offset.dx;
      }
    });
  }

  Future<void> _loadFromPreferences() async {
    final prefs = ProfilePreferences.instance;
    final savedLeft = prefs.getDouble('layout_left_panel_width') ?? 280.0;
    _leftPanelWidth = savedLeft < LayoutState.leftPanelMinWidth
        ? 280.0
        : savedLeft;
    _middlePanelRatio = prefs.getDouble('layout_middle_panel_ratio') ?? 0.5;
  }

  double _getLeftPanelWidth(double totalWidth, LayoutState layoutState) {
    if (!layoutState.multiPanel || !layoutState.leftPanelVisible) {
      return 0.0;
    }
    // Multi-panel always shows middle + right; the left sidebar may take
    // anything that's left over down to its minimum width.
    final minSpaceForMain =
        LayoutState.middlePanelMinWidth + LayoutState.rightPanelMinWidth;
    final maxLeftWidth = (totalWidth - minSpaceForMain).clamp(
      0.0,
      double.infinity,
    );
    final width = _leftPanelWidth.clamp(0.0, maxLeftWidth);
    if (width < LayoutState.leftPanelMinWidth) return 0.0;
    return width;
  }

  /// Builds a single squircle "card": a subtle drop shadow under a hairline
  /// border, with [context.colour.background] filling the rounded shape.
  /// When [paintChrome] is false, only the clip + background fill are
  /// painted — used for the middle and right main panels, which share a
  /// single squircle. Their combined shadow + border is drawn once by
  /// [_InnerHoverableResizable], avoiding per-card shadows that bleed
  /// across the shared seam (visible as a dark fade in dark mode).
  Widget _squircleCard(
    BuildContext context,
    Widget child, {
    required BorderRadiusGeometry borderRadius,
    bool paintChrome = true,
  }) {
    final clipped = ClipRSuperellipse(
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: ColoredBox(color: context.colour.background, child: child),
    );
    if (!paintChrome) return clipped;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(borderRadius: borderRadius),
        shadows: [_squircleShadow(context)],
      ),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: ShapeDecoration(
          shape: RoundedSuperellipseBorder(
            side: BorderSide(color: _squircleBorderColor(context), width: 1),
            borderRadius: borderRadius,
          ),
        ),
        child: clipped,
      ),
    );
  }

  /// Body content of the left column (agenda squircle + priorities list).
  /// The sidebar header sits above this in the column.
  Widget _buildSidebarBody(BuildContext context) {
    final bottom = widget.left;
    if (widget.leftTop == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          _outerInset,
          0,
          _halfGap,
          _outerInset,
        ),
        child: bottom,
      );
    }
    const agendaRadius = BorderRadius.all(Radius.circular(_panelRadius));
    final top = Padding(
      padding: const EdgeInsets.fromLTRB(_outerInset, 0, _halfGap, 0),
      child: _squircleCard(
        context,
        widget.leftTop!,
        borderRadius: agendaRadius,
      ),
    );
    final priorities = Padding(
      padding: const EdgeInsets.fromLTRB(
        _outerInset,
        _outerInset / 2,
        _halfGap,
        _outerInset,
      ),
      child: bottom,
    );
    return _LeftPanelVerticalSplit(top: top, bottom: priorities);
  }

  /// Body content of the main column (middle + right panels sharing one
  /// squircle, with an inner resize divider between them).
  Widget _buildMainBody(BuildContext context, {required bool hasLeftSidebar}) {
    final radius = const Radius.circular(_panelRadius);
    // Middle panel: rounded outer-left corners (the sidebar floats with a
    // gap, not a shared seam, so the middle panel is the leftmost outer
    // edge of the main squircle); flat right corners that share the
    // internal seam with the right panel.
    final middleRadiusResolved = BorderRadius.only(
      topLeft: radius,
      bottomLeft: radius,
      topRight: Radius.zero,
      bottomRight: Radius.zero,
    );
    // Right panel: flat left (shares with middle), rounded right (outer).
    final rightRadius = BorderRadius.only(
      topLeft: Radius.zero,
      bottomLeft: Radius.zero,
      topRight: radius,
      bottomRight: radius,
    );

    final leftPad = hasLeftSidebar ? _halfGap : _outerInset;
    const rightPad = _outerInset;

    // Don't paint per-card chrome — the shared overlay paints shadow +
    // border across both panels so the seam is invisible.
    Widget wrap(Widget child, BorderRadius borderRadius) => _squircleCard(
      context,
      child,
      borderRadius: borderRadius,
      paintChrome: false,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(leftPad, 0, rightPad, _outerInset),
      child: _InnerHoverableResizable(
        middle: wrap(widget.middle, middleRadiusResolved),
        right: KeyedSubtree(
          key: _rightPanelKey,
          child: wrap(widget.child, rightRadius),
        ),
        middleRatio: _middlePanelRatio,
        onMiddleRatioChanged: (r) => _middlePanelRatio = r,
      ),
    );
  }

  Widget _buildSidebarColumn(BuildContext context) {
    return ColoredBox(
      // Transparent on the priority-tinted frame.
      color: const Color(0x00000000),
      // Stretch so the unified header fills the column's width. Without
      // this, Column's default center alignment hands the header a loose
      // horizontal constraint and the FHeader shrink-wraps to its
      // non-flex content — the `Expanded(SizedBox.shrink())` between the
      // traffic-light gap and the toggle button can't expand, so the
      // toggle ends up near the middle of the column instead of at its
      // right edge, visually offsetting the panel boundary in the header
      // from the boundary defined by the body below.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const UnifiedHeader(variant: HeaderVariant.sidebar),
          Expanded(child: _buildSidebarBody(context)),
        ],
      ),
    );
  }

  Widget _buildMainColumn(
    BuildContext context, {
    required bool hasLeftSidebar,
  }) {
    return Column(
      // Same reason as [_buildSidebarColumn]: stretch so the main header's
      // `Expanded` title section can fill the available width and the
      // trailing icons land at the column's right edge.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const UnifiedHeader(variant: HeaderVariant.main),
        Expanded(child: _buildMainBody(context, hasLeftSidebar: hasLeftSidebar)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _selfKey,
      child: BlocListener<NoteViewerBloc, NoteViewerState>(
        // The inner divider can move without triggering this widget to
        // rebuild, so the cached right-panel position can be stale by the
        // time a note is viewed. Re-measure on every viewer state change.
        listener: (context, state) => _scheduleMeasureRightPanel(),
        child: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return FutureBuilder<void>(
        future: _loadPreferencesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingPage();
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              return BlocBuilder<LayoutBloc, LayoutState>(
                buildWhen: (previous, current) =>
                    previous.multiPanel != current.multiPanel ||
                    previous.leftPanelVisible != current.leftPanelVisible ||
                    previous.middlePanelVisible != current.middlePanelVisible,
                builder: (context, layoutState) {
                  _scheduleMeasureRightPanel();
                  final Widget layout;
                  if (!layoutState.multiPanel) {
                    // Single-panel: the page-level header is rendered above
                    // this widget; here we just hand back the route content.
                    layout = widget.child;
                  } else {
                    final totalWidth = constraints.maxWidth;
                    final leftWidth = _getLeftPanelWidth(
                      totalWidth,
                      layoutState,
                    );
                    final leftVisible =
                        layoutState.leftPanelVisible && leftWidth > 0;

                    if (!leftVisible) {
                      // 2-panel multi: no sidebar, just the main column with
                      // middle + right inside one shared squircle.
                      layout = _buildMainColumn(
                        context,
                        hasLeftSidebar: false,
                      );
                    } else {
                      // 3-panel multi: A | B. Outer divider top-to-bottom.
                      layout = _OuterHoverableResizable(
                        leftWidth: leftWidth,
                        totalWidth: totalWidth,
                        layoutState: layoutState,
                        onLeftWidthChanged: (width) =>
                            _leftPanelWidth = width,
                        left: _buildSidebarColumn(context),
                        right: _buildMainColumn(
                          context,
                          hasLeftSidebar: true,
                        ),
                      );
                    }
                  }

                  return Stack(
                    children: [
                      Positioned.fill(child: layout),
                      _NoteViewerOverlay(
                        isMultiPanel: layoutState.multiPanel,
                        rightPanelLeft: _rightPanelLeft,
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      );
  }
}

/// Mounts [NoteViewer] above the panel layout when [NoteViewerBloc] has a
/// viewed note. In multi-panel mode the overlay covers everything to the
/// left of the thread (right) panel — keeping the thread interactive so the
/// user can scroll it and add new notes — by anchoring its right edge to
/// [rightPanelLeft]. In single-panel mode it fills the whole layout.
class _NoteViewerOverlay extends StatelessWidget {
  const _NoteViewerOverlay({
    required this.isMultiPanel,
    required this.rightPanelLeft,
  });

  final bool isMultiPanel;
  final ValueListenable<double?> rightPanelLeft;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NoteViewerBloc, NoteViewerState>(
      builder: (context, state) {
        final note = state.note;
        if (note == null) return const SizedBox.shrink();
        if (!isMultiPanel) {
          return Positioned.fill(child: NoteViewer(note: note));
        }
        return ValueListenableBuilder<double?>(
          valueListenable: rightPanelLeft,
          builder: (context, leftEdge, _) {
            if (leftEdge == null) {
              // Position not measured yet; keep the overlay invisible for
              // one frame rather than flashing a full-width cover.
              return const SizedBox.shrink();
            }
            return Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: leftEdge,
              child: NoteViewer(note: note),
            );
          },
        );
      },
    );
  }
}

/// Outer A|B resizable: top-to-bottom drag divider that stays transparent
/// at rest and reveals an accent line on hover/drag. Persists the left
/// panel width via `layout_left_panel_width` prefs.
class _OuterHoverableResizable extends StatefulWidget {
  const _OuterHoverableResizable({
    required this.leftWidth,
    required this.totalWidth,
    required this.layoutState,
    required this.onLeftWidthChanged,
    required this.left,
    required this.right,
  });

  final double leftWidth;
  final double totalWidth;
  final LayoutState layoutState;
  final ValueChanged<double> onLeftWidthChanged;
  final Widget left;
  final Widget right;

  @override
  State<_OuterHoverableResizable> createState() =>
      _OuterHoverableResizableState();
}

class _OuterHoverableResizableState extends State<_OuterHoverableResizable> {
  bool _hovered = false;
  bool _dragging = false;
  late final FResizableController _controller;
  static const double _hitRegionExtent = 10.0;

  double _dragStartOffset = 0.0;
  double _cumulativeDelta = 0.0;
  double _dividerOffset = 0.0;

  // FResizable resets its controller back to `initialExtent` whenever
  // [_FResizableState.didUpdateWidget] sees `widget.children` change. Its
  // equality check is reference-based (the `equals` extension falls back
  // to `identical` for non-collection element types), so creating a new
  // FResizableRegion list inside the ListenableBuilder on every drag
  // notification would clobber the drag immediately. We cache the list
  // and only rebuild it when prop-driven inputs actually change.
  late List<FResizableRegion> _regions;

  @override
  void initState() {
    super.initState();
    _controller = FResizableController.cascade();
    _controller.addListener(_handleResize);
    _dividerOffset = widget.leftWidth;
    _regions = _buildRegions();
  }

  @override
  void didUpdateWidget(covariant _OuterHoverableResizable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.leftWidth != widget.leftWidth ||
        oldWidget.totalWidth != widget.totalWidth) {
      _dividerOffset = widget.leftWidth;
      _regions = _buildRegions();
    }
  }

  List<FResizableRegion> _buildRegions() {
    final rightWidth = (widget.totalWidth - widget.leftWidth).clamp(
      0.0,
      double.infinity,
    );
    final rightMin =
        LayoutState.middlePanelMinWidth + LayoutState.rightPanelMinWidth;
    final (minLeft, minRightExtent) = _resizableMinExtents(
      LayoutState.leftPanelMinWidth,
      rightMin,
      widget.leftWidth,
      rightWidth,
      widget.totalWidth,
    );
    return [
      FResizableRegion(
        key: const ValueKey('OuterLeft'),
        initialExtent: widget.leftWidth,
        minExtent: minLeft,
        // Closures read `widget.left` at execution time, so the
        // up-to-date child still renders even though the FResizableRegion
        // instance itself is cached across rebuilds.
        builder: (context, data, _) => PanelPositionProvider(
          position: HeaderPosition.left,
          child: widget.left,
        ),
      ),
      FResizableRegion(
        key: const ValueKey('OuterRight'),
        initialExtent: rightWidth,
        minExtent: minRightExtent,
        builder: (context, data, _) => PanelPositionProvider(
          position: HeaderPosition.right,
          child: widget.right,
        ),
      ),
    ];
  }

  void _handleResize() async {
    final regions = _controller.regions;
    if (regions.isEmpty) return;
    final extent = regions[0].extent.current;
    if (extent >= LayoutState.leftPanelMinWidth) {
      widget.onLeftWidthChanged(extent);
      await ProfilePreferences.instance.setDouble(
        'layout_left_panel_width',
        extent,
      );
    }
    if (_controller.regions.isNotEmpty) {
      _dividerOffset = _controller.regions[0].offset.max;
    }
  }

  void _onDragStart() {
    setState(() => _dragging = true);
    _cumulativeDelta = 0.0;
    _dragStartOffset = _dividerOffset;
  }

  void _onDragUpdate(double delta) {
    if (delta == 0.0) return;
    _cumulativeDelta += delta;
    final desired = _dragStartOffset + _cumulativeDelta;
    final actual = _controller.regions[0].offset.max;
    final gap = desired - actual;
    if (gap.abs() > 0.5 && gap * delta < 0) return;
    final adjusted = (gap.abs() > 0.5 && gap.abs() < delta.abs())
        ? gap
        : delta;
    _controller.update(0, 1, adjusted);
  }

  void _onDragEnd() {
    _controller.end(0, 1);
    setState(() {
      _dragging = false;
      _hovered = false;
    });
    _cumulativeDelta = 0.0;
    _dragStartOffset = 0.0;
  }

  @override
  void dispose() {
    _controller.removeListener(_handleResize);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colour;
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final overlayHeight = constraints.maxHeight;

          return Stack(
            children: [
              FResizable(
                control: .managedCascade(controller: _controller),
                axis: Axis.horizontal,
                divider: FResizableDivider.none,
                children: _regions,
              ),
              Transform.translate(
                offset: Offset(_dividerOffset - (_hitRegionExtent / 2), 0),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (_) => _onDragStart(),
                  onHorizontalDragUpdate: (d) => _onDragUpdate(d.delta.dx),
                  onHorizontalDragEnd: (_) => _onDragEnd(),
                  onHorizontalDragCancel: _onDragEnd,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    onEnter: (_) => setState(() => _hovered = true),
                    onExit: (_) => setState(() => _hovered = false),
                    child: SizedBox(
                      width: _hitRegionExtent,
                      height: overlayHeight,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeInOut,
                          width: (_hovered || _dragging) ? 2.0 : 1.0,
                          height: overlayHeight,
                          color: (_hovered || _dragging)
                              ? colorScheme.accent
                              // The gap between the agenda and main
                              // squircles is the visual divider — stay
                              // transparent at rest.
                              : const Color(0x00000000),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Inner middle|right resizable: lives inside the main column's body below
/// the main header. Renders the shared squircle chrome (shadow + border)
/// across both panels and a hairline divider at the seam.
class _InnerHoverableResizable extends StatefulWidget {
  const _InnerHoverableResizable({
    required this.middle,
    required this.right,
    required this.middleRatio,
    required this.onMiddleRatioChanged,
  });

  final Widget middle;
  final Widget right;
  final double middleRatio;
  final ValueChanged<double> onMiddleRatioChanged;

  @override
  State<_InnerHoverableResizable> createState() =>
      _InnerHoverableResizableState();
}

class _InnerHoverableResizableState extends State<_InnerHoverableResizable> {
  bool _hovered = false;
  bool _dragging = false;
  late final FResizableController _controller;
  static const double _hitRegionExtent = 10.0;

  double _dragStartOffset = 0.0;
  double _cumulativeDelta = 0.0;
  double _dividerOffset = 0.0;

  // Cached so the ListenableBuilder doesn't hand FResizable a new list of
  // FResizableRegion instances on every drag — that would trigger
  // [_FResizableState.didUpdateWidget]'s children-equality check, clear
  // the controller, and reset back to initialExtent, eating the drag.
  List<FResizableRegion>? _regions;
  double _lastTotalWidth = 0.0;

  @override
  void initState() {
    super.initState();
    _controller = FResizableController.cascade();
    _controller.addListener(_handleResize);
  }

  List<FResizableRegion> _buildRegions(double totalWidth) {
    final maxMiddle = (totalWidth - LayoutState.rightPanelMinWidth)
        .clamp(0.0, double.infinity);
    // Preserve the user's current middle pixel width across outer-drag
    // reflows: when totalWidth changes, the right panel absorbs the
    // delta rather than re-anchoring the divider against the persisted
    // ratio (which felt like a "jump"). The ratio is still consulted on
    // first render (controller empty) so the persisted preference
    // applies on app launch.
    double initialMiddle;
    if (_controller.regions.length >= 2 &&
        _controller.regions[0].extent.current > 0) {
      initialMiddle = _controller.regions[0].extent.current;
    } else {
      initialMiddle = totalWidth * widget.middleRatio;
    }
    initialMiddle = maxMiddle < LayoutState.middlePanelMinWidth
        ? maxMiddle
        : initialMiddle.clamp(LayoutState.middlePanelMinWidth, maxMiddle);
    final initialRight =
        (totalWidth - initialMiddle).clamp(0.0, double.infinity);
    _dividerOffset = initialMiddle;
    final (minMiddle, minRight) = _resizableMinExtents(
      LayoutState.middlePanelMinWidth,
      LayoutState.rightPanelMinWidth,
      initialMiddle,
      initialRight,
      totalWidth,
    );
    return [
      FResizableRegion(
        key: const ValueKey('InnerMiddle'),
        initialExtent: initialMiddle,
        minExtent: minMiddle,
        builder: (context, data, _) => PanelPositionProvider(
          position: HeaderPosition.middle,
          child: widget.middle,
        ),
      ),
      FResizableRegion(
        key: const ValueKey('InnerRight'),
        initialExtent: initialRight,
        minExtent: minRight,
        builder: (context, data, _) => PanelPositionProvider(
          position: HeaderPosition.right,
          child: widget.right,
        ),
      ),
    ];
  }

  void _handleResize() async {
    final regions = _controller.regions;
    if (regions.length < 2) return;
    final mid = regions[0].extent.current;
    final r = regions[1].extent.current;
    final ratio = mid / (mid + r);
    widget.onMiddleRatioChanged(ratio);
    await ProfilePreferences.instance.setDouble(
      'layout_middle_panel_ratio',
      ratio,
    );
    _dividerOffset = _controller.regions[0].offset.max;
  }

  void _onDragStart() {
    setState(() => _dragging = true);
    _cumulativeDelta = 0.0;
    _dragStartOffset = _dividerOffset;
  }

  void _onDragUpdate(double delta) {
    if (delta == 0.0) return;
    _cumulativeDelta += delta;
    final desired = _dragStartOffset + _cumulativeDelta;
    final actual = _controller.regions[0].offset.max;
    final gap = desired - actual;
    if (gap.abs() > 0.5 && gap * delta < 0) return;
    final adjusted = (gap.abs() > 0.5 && gap.abs() < delta.abs())
        ? gap
        : delta;
    _controller.update(0, 1, adjusted);
  }

  void _onDragEnd() {
    _controller.end(0, 1);
    setState(() {
      _dragging = false;
      _hovered = false;
    });
    _cumulativeDelta = 0.0;
    _dragStartOffset = 0.0;
  }

  @override
  void dispose() {
    _controller.removeListener(_handleResize);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colour;
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final overlayHeight = constraints.maxHeight;
          final totalWidth = constraints.maxWidth;
          // Recompute the cached regions only when totalWidth actually
          // changes (parent re-layout). Controller-fire rebuilds during
          // drag keep the same instances so FResizable doesn't reset.
          // [_buildRegions] reads the controller's current middle width
          // so an outer-drag-driven totalWidth change doesn't snap the
          // inner divider back to the saved ratio.
          if (_regions == null || totalWidth != _lastTotalWidth) {
            _lastTotalWidth = totalWidth;
            _regions = _buildRegions(totalWidth);
          }

          const sharedRadius =
              BorderRadius.all(Radius.circular(_panelRadius));

          return Stack(
            children: [
              // Shared squircle shadow behind both panels.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      shape: RoundedSuperellipseBorder(
                        borderRadius: sharedRadius,
                      ),
                      shadows: [_squircleShadow(context)],
                    ),
                  ),
                ),
              ),
              FResizable(
                control: .managedCascade(controller: _controller),
                axis: Axis.horizontal,
                divider: FResizableDivider.none,
                children: _regions!,
              ),
              // Shared squircle hairline border on top of the panels.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      shape: RoundedSuperellipseBorder(
                        side: BorderSide(
                          color: _squircleBorderColor(context),
                          width: 1,
                        ),
                        borderRadius: sharedRadius,
                      ),
                    ),
                  ),
                ),
              ),
              // Inner divider: quiet hairline at rest, accent on hover/drag.
              Transform.translate(
                offset: Offset(_dividerOffset - (_hitRegionExtent / 2), 0),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (_) => _onDragStart(),
                  onHorizontalDragUpdate: (d) => _onDragUpdate(d.delta.dx),
                  onHorizontalDragEnd: (_) => _onDragEnd(),
                  onHorizontalDragCancel: _onDragEnd,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    onEnter: (_) => setState(() => _hovered = true),
                    onExit: (_) => setState(() => _hovered = false),
                    child: SizedBox(
                      width: _hitRegionExtent,
                      height: overlayHeight,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeInOut,
                          width: (_hovered || _dragging) ? 2.0 : 1.0,
                          height: overlayHeight,
                          color: (_hovered || _dragging)
                              ? colorScheme.accent
                              : context.theme.colors.border.withValues(
                                  alpha: context.theme.colors.border.a * 0.35,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Vertically stacks the left panel: agenda on top fills available space,
/// priorities on the bottom sizes to its content with a 50% height cap and
/// scrolls when it would exceed that cap.
class _LeftPanelVerticalSplit extends StatelessWidget {
  const _LeftPanelVerticalSplit({required this.top, required this.bottom});

  final Widget top;
  final Widget bottom;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxBottomHeight = constraints.maxHeight * 0.5;
        return Column(
          children: [
            Expanded(child: top),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxBottomHeight),
              child: bottom,
            ),
          ],
        );
      },
    );
  }
}

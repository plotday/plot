import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/util/profile_preferences.dart';
import 'header.dart';

/// Outer inset around the squircle panel cards in multi-panel mode (window
/// edges and bottom). The header has no inset above the squircles so they
/// sit flush against the bottom of the unified header.
const double _outerInset = 14.0;

/// Half of the gap between adjacent squircles that don't share one shape
/// (e.g. left sidebar squircle vs. main-panel squircle). Split evenly across
/// the FResizable region boundary so the boundary—and its drag handle—lands
/// at the visual center of the gap.
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

  @override
  void initState() {
    super.initState();
    _loadPreferencesFuture = _loadFromPreferences();
  }

  /// Load panel dimensions from profile preferences
  Future<void> _loadFromPreferences() async {
    final prefs = ProfilePreferences.instance;
    final savedLeft = prefs.getDouble('layout_left_panel_width') ?? 280.0;
    // Clamp to minimum to recover from floating-point drift in saved values
    _leftPanelWidth = savedLeft < LayoutState.leftPanelMinWidth
        ? 280.0
        : savedLeft;
    _middlePanelRatio = prefs.getDouble('layout_middle_panel_ratio') ?? 0.5;
  }

  /// Calculate effective left panel width
  double _getLeftPanelWidth(double totalWidth, LayoutState layoutState) {
    if (!layoutState.multiPanel || !layoutState.leftPanelVisible) {
      return 0.0;
    }

    // Determine minimum space needed for other panels
    final minSpaceForOthers = layoutState.middlePanelVisible
        ? LayoutState.middlePanelMinWidth + LayoutState.rightPanelMinWidth
        : LayoutState.middlePanelMinWidth;

    // Clamp left panel width to fit within available space
    final maxLeftWidth = (totalWidth - minSpaceForOthers).clamp(
      0.0,
      double.infinity,
    );
    final width = _leftPanelWidth.clamp(0.0, maxLeftWidth);
    if (width < LayoutState.leftPanelMinWidth) return 0.0;
    return width;
  }

  /// Calculate middle panel width based on available space
  double _getMiddlePanelWidth(double totalWidth, LayoutState layoutState) {
    if (!layoutState.multiPanel || !layoutState.middlePanelVisible) {
      return 0.0;
    }

    final leftWidth = _getLeftPanelWidth(totalWidth, layoutState);
    final remainingWidth = totalWidth - leftWidth;

    // Calculate based on ratio, ensuring minimum widths
    final desiredCenterWidth = remainingWidth * _middlePanelRatio;
    final maxMiddleWidth = (remainingWidth - LayoutState.rightPanelMinWidth)
        .clamp(0.0, double.infinity);
    final width = desiredCenterWidth.clamp(0.0, maxMiddleWidth);
    if (width < LayoutState.middlePanelMinWidth) return 0.0;
    return width;
  }

  /// Calculate right panel width based on available space
  double _getRightPanelWidth(double totalWidth, LayoutState layoutState) {
    if (!layoutState.multiPanel ||
        (!layoutState.leftPanelVisible && !layoutState.middlePanelVisible)) {
      return totalWidth;
    }

    final leftWidth = _getLeftPanelWidth(totalWidth, layoutState);
    final middleWidth = _getMiddlePanelWidth(totalWidth, layoutState);

    // Calculate right panel as remainder to avoid rounding errors
    return (totalWidth - leftWidth - middleWidth).clamp(0.0, double.infinity);
  }

  /// Builds a single squircle "card": a subtle drop shadow under a hairline
  /// border, with [context.colour.background] filling the rounded shape.
  /// Modeled on Zen browser's content cards — visible but quiet edge and
  /// just enough shadow to lift the card off the tinted frame.
  ///
  /// When [paintChrome] is false, only the clip + background fill are
  /// painted. Used for the middle and right main panels when they share a
  /// single squircle: their combined shadow + border is drawn once at the
  /// layout level by [_HoverableResizable], avoiding per-card shadows that
  /// bleed across the shared seam (visible as a dark fade in dark mode).
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

  /// Builds the full left panel content: agenda on top (inside a squircle
  /// card in multi-panel mode), priorities on the bottom on the tinted frame.
  Widget _buildLeftPanel(BuildContext context, bool isMulti) {
    if (!isMulti) {
      // Single-panel mode never shows a multi-panel left panel; preserve
      // the previous chrome (panel-darkest bottom, optional border) for
      // any legacy single-panel use.
      final bottom = DecoratedBox(
        decoration: BoxDecoration(
          color: context.colour.panelDarkestBackground,
          border: widget.leftTop == null
              ? null
              : Border(
                  top: BorderSide(
                    color: context.theme.colors.border,
                    width: 1,
                  ),
                ),
        ),
        child: widget.left,
      );
      if (widget.leftTop == null) return bottom;
      return _LeftPanelVerticalSplit(top: widget.leftTop!, bottom: bottom);
    }

    // Multi-panel: priorities (bottom) sits transparently on the tinted
    // frame background. The agenda (top) is a squircle card matching the
    // priority page colors (no darken). Outer edges use [_outerInset], the
    // right edge uses [_halfGap] so the FResizable boundary lands at the
    // center of the inter-squircle gap. Top inset is 0 so the squircle
    // hugs the unified header.
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

  /// Wraps a main panel (middle or right) in a squircle card.
  ///
  /// [sharesSquircleLeft] / [sharesSquircleRight] indicate whether this
  /// region shares one squircle shape with a main-panel neighbor on that
  /// side (middle/right share when both visible). The shared edge gets flat
  /// corners and no padding so the two regions read as one card with an
  /// internal seam.
  ///
  /// [hasLeftSidebar] reports whether the left sidebar zone (agenda/
  /// priorities) precedes this region. When true, the inter-squircle gap is
  /// split evenly across the FResizable boundary using [_halfGap]; when
  /// false the outer window inset applies on this side.
  Widget _wrapMainPanel(
    BuildContext context,
    Widget child, {
    required bool isMulti,
    required bool hasLeftSidebar,
    required bool sharesSquircleLeft,
    required bool sharesSquircleRight,
  }) {
    if (!isMulti) return child;

    final radius = const Radius.circular(_panelRadius);
    final borderRadius = BorderRadius.only(
      topLeft: sharesSquircleLeft ? Radius.zero : radius,
      bottomLeft: sharesSquircleLeft ? Radius.zero : radius,
      topRight: sharesSquircleRight ? Radius.zero : radius,
      bottomRight: sharesSquircleRight ? Radius.zero : radius,
    );
    final leftPad = sharesSquircleLeft
        ? 0.0
        : (hasLeftSidebar ? _halfGap : _outerInset);
    final rightPad = sharesSquircleRight ? 0.0 : _outerInset;
    // When this panel shares a squircle with a neighbor, _HoverableResizable
    // paints the combined shadow + border as a single layer over the
    // middle+right region. Drop per-card chrome here so the shared shadow
    // doesn't bleed across the seam.
    final shared = sharesSquircleLeft || sharesSquircleRight;
    return Padding(
      padding: EdgeInsets.fromLTRB(leftPad, 0, rightPad, _outerInset),
      child: _squircleCard(
        context,
        child,
        borderRadius: borderRadius,
        paintChrome: !shared,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  // Only rebuild when layout-related state actually changes
                  previous.multiPanel != current.multiPanel ||
                  previous.leftPanelVisible != current.leftPanelVisible ||
                  previous.middlePanelVisible != current.middlePanelVisible,
              builder: (context, layoutState) {
                final totalWidth = constraints.maxWidth;
                final leftWidth = _getLeftPanelWidth(totalWidth, layoutState);
                final middleWidth = _getMiddlePanelWidth(
                  totalWidth,
                  layoutState,
                );
                final rightWidth = _getRightPanelWidth(totalWidth, layoutState);

                // Helper to calculate minExtent ensuring it's strictly less than initialExtent
                double calculateMinExtent(
                  double initialWidth,
                  double idealMin,
                ) {
                  if (initialWidth <= idealMin) {
                    // When constrained, leave 1px gap for resizability requirement
                    return (initialWidth - 1).clamp(0.0, double.infinity);
                  }
                  return idealMin;
                }

                final isMulti = layoutState.multiPanel;
                final leftVisible =
                    layoutState.leftPanelVisible && leftWidth > 0;
                final middleVisible =
                    layoutState.middlePanelVisible && middleWidth > 0;

                List<FResizableRegion> regions = [
                  if (leftVisible)
                    FResizableRegion(
                      key: const ValueKey('LeftPanel'),
                      initialExtent: leftWidth,
                      minExtent: calculateMinExtent(
                        leftWidth,
                        LayoutState.leftPanelMinWidth,
                      ),
                      builder: (context, data, _) {
                        return PanelPositionProvider(
                          key: const ValueKey('LeftPanelPositionProvider'),
                          position: HeaderPosition.left,
                          child: _buildLeftPanel(context, isMulti),
                        );
                      },
                    ),
                  if (middleVisible)
                    FResizableRegion(
                      key: const ValueKey('MiddlePanel'),
                      initialExtent: middleWidth,
                      minExtent: calculateMinExtent(
                        middleWidth,
                        LayoutState.middlePanelMinWidth,
                      ),
                      builder: (context, data, _) => PanelPositionProvider(
                        key: const ValueKey('MiddlePanelPositionProvider'),
                        position: HeaderPosition.middle,
                        child: _wrapMainPanel(
                          context,
                          widget.middle,
                          isMulti: isMulti,
                          hasLeftSidebar: leftVisible,
                          // Middle never shares a squircle on its left
                          // (the left sidebar is on the tinted frame, not
                          // inside the main-panel squircle).
                          sharesSquircleLeft: false,
                          // Right is always present, so middle shares its
                          // right edge with it.
                          sharesSquircleRight: true,
                        ),
                      ),
                    ),
                  FResizableRegion(
                    key: const ValueKey('RightPanel'),
                    initialExtent: rightWidth,
                    minExtent: calculateMinExtent(
                      rightWidth,
                      LayoutState.rightPanelMinWidth,
                    ),
                    builder: (context, data, _) => PanelPositionProvider(
                      key: const ValueKey('RightPanelPositionProvider'),
                      position: isMulti ? HeaderPosition.right : null,
                      child: _wrapMainPanel(
                        context,
                        widget.child,
                        isMulti: isMulti,
                        hasLeftSidebar: leftVisible,
                        // Right shares its left edge with middle when
                        // middle is visible; otherwise it stands alone.
                        sharesSquircleLeft: middleVisible,
                        sharesSquircleRight: false,
                      ),
                    ),
                  ),
                ];

                return _HoverableResizable(
                  regions: regions,
                  layoutState: layoutState,
                  onLeftWidthChanged: (width) {
                    _leftPanelWidth = width;
                  },
                  onMiddleRatioChanged: (ratio) {
                    _middlePanelRatio = ratio;
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// A wrapper around FResizable that provides hover effects on dividers
class _HoverableResizable extends StatefulWidget {
  final List<FResizableRegion> regions;
  final LayoutState layoutState;
  final ValueChanged<double> onLeftWidthChanged;
  final ValueChanged<double> onMiddleRatioChanged;

  const _HoverableResizable({
    required this.regions,
    required this.layoutState,
    required this.onLeftWidthChanged,
    required this.onMiddleRatioChanged,
  });

  @override
  State<_HoverableResizable> createState() => _HoverableResizableState();
}

class _HoverableResizableState extends State<_HoverableResizable> {
  int? _hoveredDividerIndex;
  late final FResizableController _controller;
  static const double _hitRegionExtent = 10.0; // Desktop hit region size

  // Drag hysteresis state: tracks gap between pointer intent and divider position
  int? _draggingDividerIndex;
  double _cumulativeDelta = 0.0;
  double _dragStartOffset = 0.0;

  // Single source of truth for overlay divider positions.
  // Updated from initialExtent on region changes (instant, no lag),
  // and from controller during drags (real-time drag positions).
  List<double> _dividerOffsets = [];

  void _computeOffsetsFromRegions() {
    double cumulative = 0;
    _dividerOffsets = [];
    for (int i = 0; i < widget.regions.length - 1; i++) {
      cumulative += widget.regions[i].initialExtent;
      _dividerOffsets.add(cumulative);
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = FResizableController.cascade();
    _controller.addListener(_handleResize);
    _computeOffsetsFromRegions();
  }

  @override
  void didUpdateWidget(covariant _HoverableResizable oldWidget) {
    super.didUpdateWidget(oldWidget);
    _computeOffsetsFromRegions();
    if (_regionsChanged(widget.regions, oldWidget.regions)) {
      _hoveredDividerIndex = null;
    }
  }

  /// Check if regions changed by count or identity (via keys)
  bool _regionsChanged(List<FResizableRegion> a, List<FResizableRegion> b) {
    if (a.length != b.length) return true;
    for (var i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key) return true;
    }
    return false;
  }

  void _handleResize() async {
    final regions = _controller.regions;
    if (regions.isEmpty) return;

    final prefs = ProfilePreferences.instance;
    double? newLeftWidth;
    double? newMiddleRatio;

    var mutableRegions = regions.toList();

    if (widget.layoutState.leftPanelVisible && mutableRegions.isNotEmpty) {
      final extent = mutableRegions[0].extent.current;
      // Don't save sub-minimum values that would hide the panel on reload
      if (extent >= LayoutState.leftPanelMinWidth) {
        newLeftWidth = extent;
        prefs.setDouble('layout_left_panel_width', newLeftWidth);
      }
      mutableRegions = mutableRegions.sublist(1);
    }
    if (widget.layoutState.middlePanelVisible && mutableRegions.length >= 2) {
      newMiddleRatio =
          mutableRegions[0].extent.current /
          (mutableRegions[0].extent.current + mutableRegions[1].extent.current);
      prefs.setDouble('layout_middle_panel_ratio', newMiddleRatio);
    }

    // Update state variables to prevent jumping on rebuild
    if (newLeftWidth != null) {
      widget.onLeftWidthChanged(newLeftWidth);
    }
    if (newMiddleRatio != null) {
      widget.onMiddleRatioChanged(newMiddleRatio);
    }

    // Sync divider offsets from controller during/after drags
    if (_controller.regions.length == widget.regions.length) {
      _dividerOffsets = [
        for (int i = 0; i < _controller.regions.length - 1; i++)
          _controller.regions[i].offset.max,
      ];
    }
  }

  void _onDragStart(int dividerIndex) {
    setState(() {
      _draggingDividerIndex = dividerIndex;
    });
    _cumulativeDelta = 0.0;
    _dragStartOffset = _dividerOffsets[dividerIndex];
  }

  void _onDragUpdate(int dividerIndex, double delta) {
    if (delta == 0.0) return;

    _cumulativeDelta += delta;

    // Where the pointer wants the divider vs where it actually is
    final desiredOffset = _dragStartOffset + _cumulativeDelta;
    final actualOffset = _controller.regions[dividerIndex].offset.max;
    final gap = desiredOffset - actualOffset;

    // If pointer hasn't caught up to divider yet, skip
    if (gap.abs() > 0.5 && gap * delta < 0) return;

    // Cap delta so divider doesn't overshoot pointer position
    final adjustedDelta = (gap.abs() > 0.5 && gap.abs() < delta.abs())
        ? gap
        : delta;
    _controller.update(dividerIndex, dividerIndex + 1, adjustedDelta);
  }

  void _onDragEnd(int dividerIndex) {
    _controller.end(dividerIndex, dividerIndex + 1);
    setState(() {
      _draggingDividerIndex = null;
      _hoveredDividerIndex = null;
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
    final isMulti = widget.layoutState.multiPanel;
    // Detect whether the layout currently has the middle and left regions
    // by inspecting the region keys (the parent omits a region entirely
    // when it can't fit, so layoutState's visibility flags can disagree).
    final hasMiddle = widget.regions.any(
      (r) => r.key == const ValueKey('MiddlePanel'),
    );
    final hasLeft = widget.regions.any(
      (r) => r.key == const ValueKey('LeftPanel'),
    );
    final sharedSquircle = isMulti && hasMiddle;

    return ListenableBuilder(
      listenable: _controller,
      builder: (context, child) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final overlayHeight = constraints.maxHeight;

            // Squircle vertical extent: from top (flush against header)
            // to overlayHeight - _outerInset (bottom inset). Dividers in
            // multi-panel mode visually match this height so hover lines
            // never extend past the squircle bounds.
            final squircleHeight = isMulti
                ? (overlayHeight - _outerInset).clamp(0.0, overlayHeight)
                : overlayHeight;

            // Combined squircle bounds spanning middle + right. Outer left
            // edge sits at _halfGap past the left↔middle divider (or at
            // _outerInset when there is no left sidebar); outer right edge
            // is the window inset from the right.
            double? sharedLeft;
            double? sharedWidth;
            if (sharedSquircle) {
              final leftEdge = (hasLeft && _dividerOffsets.isNotEmpty)
                  ? _dividerOffsets[0] + _halfGap
                  : _outerInset;
              final rightEdge = constraints.maxWidth - _outerInset;
              sharedLeft = leftEdge;
              sharedWidth = (rightEdge - leftEdge).clamp(
                0.0,
                constraints.maxWidth,
              );
            }
            const sharedRadius = BorderRadius.all(
              Radius.circular(_panelRadius),
            );

            // The divider between two main-panel regions (middle ↔ right)
            // sits INSIDE a single shared squircle and gets a visible 1px
            // line at rest. Any other divider (left sidebar ↔ main panel)
            // sits in the tinted gap between two squircles and stays
            // transparent at rest.
            bool isInsideSquircle(int dividerIndex) {
              if (!isMulti) return false;
              if (!widget.layoutState.middlePanelVisible) return false;
              // When middle is visible, the middle↔right divider is the
              // last entry in the divider list.
              return dividerIndex == _dividerOffsets.length - 1;
            }

            return Stack(
              children: [
                // Shared squircle shadow behind the middle+right combined
                // region. Painted once at the layout level so the shadow
                // hugs only the outer perimeter; the seam between middle
                // and right is invisible to the shadow.
                if (sharedSquircle && sharedWidth! > 0)
                  Positioned(
                    left: sharedLeft,
                    top: 0,
                    width: sharedWidth,
                    height: squircleHeight,
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
                // The actual resizable widget with no divider
                FResizable(
                  control: .managedCascade(controller: _controller),
                  axis: Axis.horizontal,
                  divider: FResizableDivider.none,
                  children: widget.regions,
                ),
                // Shared squircle hairline above the combined region's
                // content. Stays below the divider overlays so hover/drag
                // highlights still paint on top of it.
                if (sharedSquircle && sharedWidth! > 0)
                  Positioned(
                    left: sharedLeft,
                    top: 0,
                    width: sharedWidth,
                    height: squircleHeight,
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
                // Overlay dividers with drag hysteresis handling.
                // Use Transform.translate instead of Positioned to
                // guarantee repaint on position change (RenderTransform
                // calls markNeedsPaint; Positioned only marks layout).
                if (_dividerOffsets.length == widget.regions.length - 1)
                  for (var i = 0; i < _dividerOffsets.length; i++)
                    Transform.translate(
                      offset: Offset(
                        _dividerOffsets[i] - (_hitRegionExtent / 2),
                        0.0,
                      ),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: (_) => _onDragStart(i),
                        onHorizontalDragUpdate: (details) =>
                            _onDragUpdate(i, details.delta.dx),
                        onHorizontalDragEnd: (_) => _onDragEnd(i),
                        onHorizontalDragCancel: () => _onDragEnd(i),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeLeftRight,
                          onEnter: (_) =>
                              setState(() => _hoveredDividerIndex = i),
                          onExit: (_) =>
                              setState(() => _hoveredDividerIndex = null),
                          child: SizedBox(
                            width: _hitRegionExtent,
                            height: overlayHeight,
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                curve: Curves.easeInOut,
                                width:
                                    (_hoveredDividerIndex == i ||
                                        _draggingDividerIndex == i)
                                    ? 2.0
                                    : (isInsideSquircle(i) ? 2.0 : 1),
                                height: squircleHeight,
                                color:
                                    (_hoveredDividerIndex == i ||
                                        _draggingDividerIndex == i)
                                    ? colorScheme.accent
                                    : isInsideSquircle(i)
                                    // Internal seam between middle and
                                    // right within a shared squircle —
                                    // keep it quiet so it reads as a
                                    // subtle separator, not an outline.
                                    ? context.theme.colors.border.withValues(
                                        alpha:
                                            context.theme.colors.border.a *
                                            0.35,
                                      )
                                    : isMulti
                                    // Multi-panel inter-squircle gap
                                    // provides the visual separation; no
                                    // line needed at rest.
                                    ? const Color(0x00000000)
                                    : context.theme.colors.border,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
              ],
            );
          },
        );
      },
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

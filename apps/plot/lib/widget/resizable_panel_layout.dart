import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/util/profile_preferences.dart';
import 'header.dart';

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
  double _leftTopHeight = LayoutState.leftTopPanelDefaultHeight;
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
    final savedLeftTop = prefs.getDouble('layout_left_top_panel_height');
    _leftTopHeight = savedLeftTop == null
        ? LayoutState.leftTopPanelDefaultHeight
        : savedLeftTop < LayoutState.leftTopPanelMinHeight
        ? LayoutState.leftTopPanelDefaultHeight
        : savedLeftTop;
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

                List<FResizableRegion> regions = [
                  if (layoutState.leftPanelVisible && leftWidth > 0)
                    FResizableRegion(
                      key: const ValueKey('LeftPanel'),
                      initialExtent: leftWidth,
                      minExtent: calculateMinExtent(
                        leftWidth,
                        LayoutState.leftPanelMinWidth,
                      ),
                      builder: (context, data, _) => PanelPositionProvider(
                        key: ValueKey('LeftPanelPositionProvider'),
                        position: HeaderPosition.left,
                        child: FTheme(
                          data: darkenTheme(
                            context,
                            context.theme,
                            context.colour,
                            steps: 2,
                          ),
                          child: widget.leftTop == null
                              ? widget.left
                              : _LeftPanelVerticalSplit(
                                  top: widget.leftTop!,
                                  bottom: widget.left,
                                  initialTopHeight: _leftTopHeight,
                                  onTopHeightChanged: (height) {
                                    _leftTopHeight = height;
                                    ProfilePreferences.instance.setDouble(
                                      'layout_left_top_panel_height',
                                      height,
                                    );
                                  },
                                ),
                        ),
                      ),
                    ),
                  if (layoutState.middlePanelVisible && middleWidth > 0)
                    FResizableRegion(
                      key: const ValueKey('MiddlePanel'),
                      initialExtent: middleWidth,
                      minExtent: calculateMinExtent(
                        middleWidth,
                        LayoutState.middlePanelMinWidth,
                      ),
                      builder: (context, data, _) => PanelPositionProvider(
                        key: ValueKey('MiddlePanelPositionProvider'),
                        position: HeaderPosition.middle,
                        child: widget.middle,
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
                      key: ValueKey('RightPanelPositionProvider'),
                      position: layoutState.multiPanel
                          ? HeaderPosition.right
                          : null,
                      child: widget.child,
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
    _draggingDividerIndex = dividerIndex;
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
    _draggingDividerIndex = null;
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
      builder: (context, child) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final overlayHeight = constraints.maxHeight;

            return Stack(
              children: [
                // The actual resizable widget with no divider
                FResizable(
                  control: .managedCascade(controller: _controller),
                  axis: Axis.horizontal,
                  divider: FResizableDivider.none,
                  children: widget.regions,
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
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeLeftRight,
                          onEnter: (_) =>
                              setState(() => _hoveredDividerIndex = i),
                          onExit: (_) =>
                              setState(() => _hoveredDividerIndex = null),
                          child: SizedBox(
                            width: _hitRegionExtent,
                            height: overlayHeight,
                            child: Center(
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                curve: Curves.easeInOut,
                                width:
                                    (_hoveredDividerIndex == i ||
                                        _draggingDividerIndex == i)
                                    ? 2.0
                                    : 1,
                                height: overlayHeight,
                                color:
                                    (_hoveredDividerIndex == i ||
                                        _draggingDividerIndex == i)
                                    ? colorScheme.accent
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

/// Vertically splits the left panel into a top and bottom region with a
/// draggable horizontal divider. The top height is bounded by
/// [LayoutState.leftTopPanelMinHeight] / [LayoutState.leftBottomPanelMinHeight]
/// and persisted by the parent via [onTopHeightChanged].
class _LeftPanelVerticalSplit extends StatefulWidget {
  const _LeftPanelVerticalSplit({
    required this.top,
    required this.bottom,
    required this.initialTopHeight,
    required this.onTopHeightChanged,
  });

  final Widget top;
  final Widget bottom;
  final double initialTopHeight;
  final ValueChanged<double> onTopHeightChanged;

  @override
  State<_LeftPanelVerticalSplit> createState() =>
      _LeftPanelVerticalSplitState();
}

class _LeftPanelVerticalSplitState extends State<_LeftPanelVerticalSplit> {
  static const double _hitRegionExtent = 10.0;

  double _topHeight = 0;
  bool _hovered = false;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _topHeight = widget.initialTopHeight;
  }

  @override
  void didUpdateWidget(covariant _LeftPanelVerticalSplit oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Don't fight the parent's persisted value if it changes while we're
    // not dragging (e.g. profile switch). During a drag, ignore parent
    // pushes so the divider tracks the pointer cleanly.
    if (!_dragging && oldWidget.initialTopHeight != widget.initialTopHeight) {
      _topHeight = widget.initialTopHeight;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colour;
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalHeight = constraints.maxHeight;
        final maxTopHeight =
            (totalHeight - LayoutState.leftBottomPanelMinHeight).clamp(
              LayoutState.leftTopPanelMinHeight,
              double.infinity,
            );
        final clampedTopHeight = _topHeight.clamp(
          LayoutState.leftTopPanelMinHeight,
          maxTopHeight,
        );

        return Stack(
          children: [
            Column(
              children: [
                SizedBox(height: clampedTopHeight, child: widget.top),
                Expanded(child: widget.bottom),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              top: clampedTopHeight - (_hitRegionExtent / 2),
              height: _hitRegionExtent,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (_) => setState(() => _dragging = true),
                onVerticalDragUpdate: (details) {
                  setState(() {
                    _topHeight = (clampedTopHeight + details.delta.dy).clamp(
                      LayoutState.leftTopPanelMinHeight,
                      maxTopHeight,
                    );
                  });
                },
                onVerticalDragEnd: (_) {
                  setState(() => _dragging = false);
                  widget.onTopHeightChanged(_topHeight);
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpDown,
                  onEnter: (_) => setState(() => _hovered = true),
                  onExit: (_) => setState(() => _hovered = false),
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeInOut,
                      height: (_hovered || _dragging) ? 2.0 : 1.0,
                      color: (_hovered || _dragging)
                          ? colorScheme.accent
                          : context.theme.colors.border,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

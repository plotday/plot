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
    required this.middle,
    required this.child,
    super.key,
  });

  /// Left panel
  final Widget left;

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
  final ValueNotifier<double> _headerHeight = ValueNotifier<double>(0.0);

  @override
  void initState() {
    super.initState();
    _loadPreferencesFuture = _loadFromPreferences();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    _headerHeight.dispose();
    super.dispose();
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
                        child: FAnimatedTheme(
                          data: darkenTheme(
                            context,
                            context.theme,
                            context.colour,
                          ),
                          child: widget.left,
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

                return HeaderHeightProvider(
                  notifier: _headerHeight,
                  child: Column(
                    mainAxisSize: MainAxisSize.max,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _HoverableResizable(
                          regions: regions,
                          layoutState: layoutState,
                          headerHeight: _headerHeight,
                          onLeftWidthChanged: (width) {
                            _leftPanelWidth = width;
                          },
                          onMiddleRatioChanged: (ratio) {
                            _middlePanelRatio = ratio;
                          },
                        ),
                      ),
                    ],
                  ),
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
  final ValueNotifier<double> headerHeight;
  final ValueChanged<double> onLeftWidthChanged;
  final ValueChanged<double> onMiddleRatioChanged;

  const _HoverableResizable({
    required this.regions,
    required this.layoutState,
    required this.headerHeight,
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
  BoxConstraints? _previousConstraints;

  // Drag hysteresis state: tracks gap between pointer intent and divider position
  int? _draggingDividerIndex;
  double _cumulativeDelta = 0.0;
  double _dragStartOffset = 0.0;

  @override
  void initState() {
    super.initState();
    _controller = FResizableController.cascade();
    _controller.addListener(_handleResize);
  }

  @override
  void didUpdateWidget(covariant _HoverableResizable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_regionsChanged(widget.regions, oldWidget.regions)) {
      _hoveredDividerIndex = null;
      // The controller's region offsets update during FResizable's layout phase,
      // after this build. Force a post-frame rebuild so the overlay dividers
      // pick up the correct positions.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
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
  }

  void _onDragStart(int dividerIndex) {
    _draggingDividerIndex = dividerIndex;
    _cumulativeDelta = 0.0;
    _dragStartOffset = _controller.regions[dividerIndex].offset.max;
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

    return LayoutBuilder(
      builder: (context, constraints) {
        if (_previousConstraints != null &&
            _previousConstraints != constraints) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
        _previousConstraints = constraints;

        return ListenableBuilder(
          listenable: _controller,
          builder: (context, child) {
            return ValueListenableBuilder<double>(
              valueListenable: widget.headerHeight,
              builder: (context, headerHeight, _) {
                final overlayTop = headerHeight;
                final overlayHeight = constraints.maxHeight - headerHeight;

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
                    // Skip when controller regions are stale (count mismatch)
                    // to avoid rendering dividers at wrong positions.
                    if (_controller.regions.length ==
                            widget.regions.length &&
                        _controller.regions.isNotEmpty)
                      for (var i = 0; i < _controller.regions.length - 1; i++)
                        Transform.translate(
                          offset: Offset(
                            _controller.regions[i].offset.max -
                                (_hitRegionExtent / 2),
                            overlayTop,
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
                                    width: (_hoveredDividerIndex == i ||
                                            _draggingDividerIndex == i)
                                        ? 2.0
                                        : 0.5,
                                    height: overlayHeight,
                                    color: (_hoveredDividerIndex == i ||
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
      },
    );
  }
}

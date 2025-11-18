import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/page/loading.dart';
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
    super.dispose();
  }

  /// Load panel dimensions from shared preferences
  Future<void> _loadFromPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _leftPanelWidth = prefs.getDouble('layout_left_panel_width') ?? 280.0;
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
    return _leftPanelWidth.clamp(0.0, maxLeftWidth);
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
    return desiredCenterWidth.clamp(0.0, maxMiddleWidth);
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
                  if (layoutState.leftPanelVisible)
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
                        child: widget.left,
                      ),
                    ),
                  if (layoutState.middlePanelVisible)
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
                      position: HeaderPosition.right,
                      child: widget.child,
                    ),
                  ),
                ];

                return Column(
                  mainAxisSize: MainAxisSize.max,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: FResizable(
                        axis: Axis.horizontal,
                        divider: FResizableDivider.divider,
                        onChange: (regions) async {
                          final prefs = await SharedPreferences.getInstance();
                          double? newLeftWidth;
                          double? newMiddleRatio;

                          if (layoutState.leftPanelVisible &&
                              regions[0].index == 0) {
                            newLeftWidth = regions[0].extent.current;
                            prefs.setDouble(
                              'layout_left_panel_width',
                              newLeftWidth,
                            );
                            regions = regions.sublist(1);
                          }
                          if (layoutState.middlePanelVisible &&
                              regions.length == 2) {
                            newMiddleRatio = regions[0].extent.current /
                                (regions[0].extent.current +
                                    regions[1].extent.current);
                            prefs.setDouble(
                              'layout_middle_panel_ratio',
                              newMiddleRatio,
                            );
                          }

                          // Update state variables to prevent jumping on rebuild
                          setState(() {
                            if (newLeftWidth != null) {
                              _leftPanelWidth = newLeftWidth;
                            }
                            if (newMiddleRatio != null) {
                              _middlePanelRatio = newMiddleRatio;
                            }
                          });
                        },
                        children: regions,
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

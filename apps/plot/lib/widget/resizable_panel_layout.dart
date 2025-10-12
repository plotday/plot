import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/layout.dart';
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
  double _rightPanelRatio = 0.5;

  @override
  void initState() {
    super.initState();
    _loadFromPreferences();
  }

  /// Load panel dimensions from shared preferences
  Future<void> _loadFromPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final leftPanelWidth = prefs.getDouble('layout_left_panel_width') ?? 280.0;
    final rightPanelRatio = prefs.getDouble('layout_right_panel_ratio') ?? 0.5;

    if (mounted) {
      setState(() {
        _leftPanelWidth = leftPanelWidth;
        _rightPanelRatio = rightPanelRatio;
      });
    }
  }

  /// Calculate effective left panel width
  double _getLeftPanelWidth(double totalWidth, LayoutState layoutState) {
    if (!layoutState.multiPanel || !layoutState.leftPanelVisible) {
      return 0.0;
    }

    // Determine minimum space needed for other panels
    final minSpaceForOthers = layoutState.rightPanelVisible
        ? LayoutState.centerPanelMinWidth + LayoutState.rightPanelMinWidth
        : LayoutState.centerPanelMinWidth;

    // Clamp left panel width to fit within available space
    final maxLeftWidth = totalWidth - minSpaceForOthers;
    return _leftPanelWidth.clamp(
      LayoutState.leftPanelMinWidth,
      maxLeftWidth.clamp(LayoutState.leftPanelMinWidth, double.infinity),
    );
  }

  /// Calculate center panel width based on available space
  double _getCenterPanelWidth(double totalWidth, LayoutState layoutState) {
    final leftWidth = _getLeftPanelWidth(totalWidth, layoutState);
    final remainingWidth = totalWidth - leftWidth;

    if (!layoutState.multiPanel || !layoutState.rightPanelVisible) {
      // Single panel or right panel not visible, center gets all remaining width
      return remainingWidth.clamp(
        LayoutState.centerPanelMinWidth,
        double.infinity,
      );
    }

    // Calculate based on ratio, ensuring minimum widths
    final desiredRightWidth = remainingWidth * _rightPanelRatio;
    final desiredCenterWidth = remainingWidth * (1.0 - _rightPanelRatio);

    // Ensure minimum widths are respected
    if (desiredCenterWidth < LayoutState.centerPanelMinWidth) {
      return LayoutState.centerPanelMinWidth;
    }
    if (desiredRightWidth < LayoutState.rightPanelMinWidth) {
      return (remainingWidth - LayoutState.rightPanelMinWidth).clamp(
        LayoutState.centerPanelMinWidth,
        double.infinity,
      );
    }

    return desiredCenterWidth;
  }

  /// Calculate right panel width based on available space
  double _getRightPanelWidth(double totalWidth, LayoutState layoutState) {
    if (!layoutState.multiPanel || !layoutState.rightPanelVisible) {
      return 0.0;
    }

    final leftWidth = _getLeftPanelWidth(totalWidth, layoutState);
    final centerWidth = _getCenterPanelWidth(totalWidth, layoutState);

    // Calculate right panel as remainder to avoid rounding errors
    final rightWidth = totalWidth - leftWidth - centerWidth;

    return rightWidth.clamp(
      LayoutState.rightPanelMinWidth,
      double.infinity,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return BlocBuilder<LayoutBloc, LayoutState>(
          builder: (context, layoutState) {
            if (!layoutState.multiPanel) {
              return widget.child;
            }

            final totalWidth = constraints.maxWidth;

            final leftWidth = _getLeftPanelWidth(totalWidth, layoutState);
            final centerWidth = _getCenterPanelWidth(totalWidth, layoutState);
            final rightWidth = _getRightPanelWidth(totalWidth, layoutState);

            List<FResizableRegion> regions = [
              if (layoutState.leftPanelVisible)
                FResizableRegion(
                  initialExtent: leftWidth,
                  minExtent: LayoutState.leftPanelMinWidth,
                  builder: (context, data, _) => PanelPositionProvider(
                    position: HeaderPosition.left,
                    child: widget.left,
                  ),
                ),
              if (layoutState.rightPanelPossible)
                FResizableRegion(
                  initialExtent: centerWidth,
                  minExtent: LayoutState.centerPanelMinWidth,
                  builder: (context, data, _) => PanelPositionProvider(
                    position: HeaderPosition.middle,
                    child: widget.middle,
                  ),
                ),
              if (layoutState.rightPanelVisible ||
                  !layoutState.rightPanelPossible)
                FResizableRegion(
                  initialExtent: layoutState.rightPanelVisible
                      ? rightWidth
                      : centerWidth,
                  minExtent: layoutState.rightPanelVisible
                      ? LayoutState.rightPanelMinWidth
                      : LayoutState.centerPanelMinWidth,
                  builder: (context, data, _) => PanelPositionProvider(
                    position: layoutState.rightPanelPossible
                        ? HeaderPosition.right
                        : HeaderPosition.middle,
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
                    children: regions,
                  ),
                ),
                // if (!layoutState.rightPanelVisible &&
                //     layoutState.rightPanelPossible)
                //   Visibility(
                //     visible: false,
                //     maintainState: true,
                //     maintainAnimation: true,
                //     maintainSize: true,
                //     child: widget.child,
                //   ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Collapsible wrapper for panels that can be hidden
class CollapsiblePanel extends StatelessWidget {
  const CollapsiblePanel({
    required this.isVisible,
    required this.child,
    super.key,
  });

  final bool isVisible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: isVisible ? null : 0,
      child: isVisible ? child : const SizedBox.shrink(),
    );
  }
}

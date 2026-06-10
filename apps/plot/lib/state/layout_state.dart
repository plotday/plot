part of 'layout.dart';

/// Immutable layout state
class LayoutState extends Equatable {
  const LayoutState({
    required this.leftPanelVisible,
    required this.middlePanelVisible,
    required this.multiPanel,
    this.canDockSidebar = false,
    this.drawerOpen = false,
  });

  /// Whether left panel is visible
  final bool leftPanelVisible;

  /// Whether middle panel is visible
  final bool middlePanelVisible;

  /// Whether layout supports multiple panels (based on screen width)
  final bool multiPanel;

  /// Whether the window is wide enough to dock the left sidebar as a third
  /// permanent column (width ≥ [threePanelMinWidth]). Below this, multi-panel
  /// mode shows only the middle + right panels and the sidebar is reachable
  /// only as an overlay drawer.
  final bool canDockSidebar;

  /// Whether the overlay sidebar drawer is currently open. Only meaningful
  /// when [sidebarIsOverlay] is true (the two-panel band); forced false in
  /// single-panel and three-panel modes.
  final bool drawerOpen;

  /// Whether the sidebar can only be shown as a temporary overlay drawer —
  /// multi-panel mode that's too narrow to dock a third column. In this band
  /// the "open sidebar" affordance opens [drawerOpen] instead of docking.
  bool get sidebarIsOverlay => multiPanel && !canDockSidebar;

  /// Whether layout is in 2-panel mode (multi-panel but not all 3 visible)
  bool get isTwoPanel =>
      multiPanel && !(leftPanelVisible && middlePanelVisible);

  /// Minimum width constraints per spec
  static const double leftPanelMinWidth = 250.0;
  static const double middlePanelMinWidth = 350.0;
  static const double rightPanelMinWidth = 350.0;

  /// Minimum width for multi-panel layout
  /// Buffer accounts for dividers and ensures min < max for resizable regions
  static final double multiPanelMinWidth = max(
    leftPanelMinWidth + middlePanelMinWidth + 60,
    middlePanelMinWidth + rightPanelMinWidth + 60,
  );

  /// Minimum width for three panel layout
  static final double threePanelMinWidth =
      leftPanelMinWidth + middlePanelMinWidth + rightPanelMinWidth + 60 + 60;

  /// Check if we should use multi-panel layout based on width
  static bool isMultiPanel(double width) {
    return width >= multiPanelMinWidth;
  }

  /// Create a copy with updated properties
  LayoutState copyWith({
    bool? leftPanelVisible,
    bool? middlePanelVisible,
    bool? multiPanel,
    bool? canDockSidebar,
    bool? drawerOpen,
  }) {
    return LayoutState(
      leftPanelVisible: leftPanelVisible ?? this.leftPanelVisible,
      middlePanelVisible: middlePanelVisible ?? this.middlePanelVisible,
      multiPanel: multiPanel ?? this.multiPanel,
      canDockSidebar: canDockSidebar ?? this.canDockSidebar,
      drawerOpen: drawerOpen ?? this.drawerOpen,
    );
  }

  @override
  List<Object?> get props => [
    leftPanelVisible,
    middlePanelVisible,
    multiPanel,
    canDockSidebar,
    drawerOpen,
  ];
}

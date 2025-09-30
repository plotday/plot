part of 'layout.dart';

/// Immutable layout state
class LayoutState extends Equatable {
  const LayoutState({
    required this.leftPanelVisible,
    required this.rightPanelVisible,
    required this.rightPanelPossible,
    required this.multiPanel,
  });

  /// Whether left panel is visible
  final bool leftPanelVisible;

  /// Whether right panel is visible
  final bool rightPanelVisible;

  /// Whether layout supports multiple panels (based on screen width)
  final bool multiPanel;

  /// Whether there's enough width to show right panel if requested
  final bool rightPanelPossible;

  bool get showBackButton => !multiPanel || !rightPanelVisible;

  /// Minimum width constraints per spec
  static const double leftPanelMinWidth = 250.0;
  static const double centerPanelMinWidth = 350.0;
  static const double rightPanelMinWidth = 350.0;

  /// Minimum width for multi-panel layout
  static final double multiPanelMinWidth = max(
    leftPanelMinWidth + centerPanelMinWidth + 5,
    centerPanelMinWidth + rightPanelMinWidth + 5,
  );

  /// Minimum width for three panel layout
  static final double threePanelMinWidth =
      leftPanelMinWidth + centerPanelMinWidth + rightPanelMinWidth + 5 + 5;

  /// Check if we should use multi-panel layout based on width
  static bool isMultiPanel(double width) {
    return width >= multiPanelMinWidth;
  }

  /// Create a copy with updated properties
  LayoutState copyWith({
    bool? leftPanelVisible,
    bool? rightPanelVisible,
    bool? rightPanelPossible,
    bool? multiPanel,
  }) {
    return LayoutState(
      leftPanelVisible: leftPanelVisible ?? this.leftPanelVisible,
      rightPanelVisible: rightPanelVisible ?? this.rightPanelVisible,
      rightPanelPossible: rightPanelPossible ?? this.rightPanelPossible,
      multiPanel: multiPanel ?? this.multiPanel,
    );
  }

  @override
  List<Object?> get props => [
    leftPanelVisible,
    rightPanelVisible,
    rightPanelPossible,
    multiPanel,
  ];
}

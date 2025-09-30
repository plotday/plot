import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'logging.dart';

part 'layout_state.dart';

/// Layout bloc (cubit) for managing layout state
class LayoutBloc extends Cubit<LayoutState> {
  LayoutBloc()
    : leftPanelRequested = true,
      rightPanelAvailable = false,
      super(
        const LayoutState(
          leftPanelVisible: false,
          rightPanelVisible: false,
          rightPanelPossible: false,
          multiPanel: false,
        ),
      ) {
    _loadFromPreferences();
  }

  double width = 0.0;
  // User has requested left panel visibility.
  // if there's insufficient width, it will still be hidden.
  bool leftPanelRequested;
  // Right panel is available.
  // If there's insufficient width, it will still be hidden.
  bool rightPanelAvailable;

  /// Update layout based on available width
  void _setWidth(double width) {
    this.width = width;
    _recalculate();
  }

  void _recalculate() {
    final isMulti = LayoutState.isMultiPanel(width);
    bool effectiveLeftVisible = false;
    bool effectiveRightVisible = false;
    bool rightPanelPossible = false;
    if (isMulti) {
      effectiveLeftVisible = leftPanelRequested;
      effectiveRightVisible = rightPanelAvailable;
      // Check if there's enough space for both panels when both are preferred
      final canShowBoth = width >= LayoutState.threePanelMinWidth;
      if (!canShowBoth && leftPanelRequested && rightPanelAvailable) {
        // Not enough space for both panels, prefer left panel
        effectiveRightVisible = false;
      }
      rightPanelPossible = canShowBoth || !leftPanelRequested;
    } else {
      rightPanelAvailable = false;
    }

    emit(
      state.copyWith(
        multiPanel: isMulti,
        leftPanelVisible: effectiveLeftVisible,
        rightPanelVisible: effectiveRightVisible,
        rightPanelPossible: rightPanelPossible,
      ),
    );
  }

  void setLeftPanelVisible(bool visible) {
    leftPanelRequested = visible;
    _recalculate();
    _persistState();
  }

  void setRightPanelVisible(bool visible) {
    rightPanelAvailable = visible;
    _recalculate();
  }

  /// Load state from shared preferences
  Future<void> _loadFromPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    leftPanelRequested = prefs.getBool('layout_left_panel_visible') ?? true;
    _recalculate();
  }

  /// Persist state to shared preferences
  Future<void> _persistState() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setBool('layout_left_panel_visible', leftPanelRequested),
    ]);
  }
}

/// Provider widget for layout bloc
class LayoutStateProvider extends StatelessWidget {
  const LayoutStateProvider({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => LayoutBloc(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Update layout bloc with current width
          context.read<LayoutBloc>()._setWidth(constraints.maxWidth);
          return child;
        },
      ),
    );
  }
}

import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:forui/forui.dart';

import 'package:plot/util/profile_preferences.dart';
import 'package:plot/style/spacing.dart';

part 'layout_state.dart';

/// Layout bloc (cubit) for managing layout state
class LayoutBloc extends Cubit<LayoutState> {
  LayoutBloc()
    : leftPanelRequested = true,
      middlePanelRequested = true,
      super(
        const LayoutState(
          leftPanelVisible: false,
          middlePanelVisible: false,
          multiPanel: false,
        ),
      ) {
    _loadFromPreferences();
  }

  double width = 0.0;
  // User has requested left panel visibility.
  // if there's insufficient width, it will still be hidden.
  bool leftPanelRequested;
  // User has requested middle panel visibility.
  // If there's insufficient width, it will still be hidden.
  bool middlePanelRequested;

  /// Update layout based on available width
  void _setWidth(double width) {
    this.width = width;
    _recalculate();
  }

  void _recalculate({bool preferMiddle = false, bool explicit = false}) {
    final isMulti = LayoutState.isMultiPanel(width);
    bool effectiveLeftVisible = false;
    bool effectiveMiddleVisible = false;
    if (isMulti) {
      effectiveLeftVisible = leftPanelRequested;
      effectiveMiddleVisible = middlePanelRequested;
      // Check if there's enough space for both panels when both are preferred
      final canShowBoth = width >= LayoutState.threePanelMinWidth;
      if (!canShowBoth && leftPanelRequested && middlePanelRequested) {
        if (preferMiddle) {
          // Not enough space for both panels, prefer middle panel
          effectiveLeftVisible = false;
        } else {
          // Not enough space for both panels, prefer left panel
          effectiveMiddleVisible = false;
        }
        if (explicit) {
          // Update requested states to match effective states
          leftPanelRequested = effectiveLeftVisible;
          middlePanelRequested = effectiveMiddleVisible;
        }
      }
    } else {
      effectiveMiddleVisible = false;
    }

    emit(
      state.copyWith(
        multiPanel: isMulti,
        leftPanelVisible: effectiveLeftVisible,
        middlePanelVisible: effectiveMiddleVisible,
      ),
    );
  }

  void setLeftPanelVisible(bool visible) {
    leftPanelRequested = visible;
    _recalculate(explicit: true);
    _persistState();
  }

  void setMiddlePanelVisible(bool visible) {
    middlePanelRequested = visible;
    _recalculate(explicit: true, preferMiddle: true);
    _persistState();
  }

  /// Set both panel visibilities atomically before recalculating.
  void setPanelVisibility({bool? left, bool? middle}) {
    if (left != null) leftPanelRequested = left;
    if (middle != null) middlePanelRequested = middle;
    _recalculate();
    _persistState();
  }

  /// Load state from profile preferences
  Future<void> _loadFromPreferences() async {
    final prefs = ProfilePreferences.instance;
    leftPanelRequested = prefs.getBool('layout_left_panel_visible') ?? true;
    middlePanelRequested = prefs.getBool('layout_middle_panel_visible') ?? true;
    _recalculate();
  }

  /// Persist state to profile preferences
  Future<void> _persistState() async {
    final prefs = ProfilePreferences.instance;
    await Future.wait([
      prefs.setBool('layout_left_panel_visible', leftPanelRequested),
      prefs.setBool('layout_middle_panel_visible', middlePanelRequested),
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

/// Extension to access multiPanel state from any context (without requiring LayoutBloc)
extension LayoutHelpers on BuildContext {
  /// Check if current screen width supports multi-panel layout
  bool get isMultiPanel {
    return LayoutState.isMultiPanel(MediaQuery.of(this).size.width);
  }

  /// Horizontal content padding — wider on desktop for breathing room.
  double get contentPaddingH {
    final spacing = FTheme.of(this).spacing;
    return isMultiPanel ? spacing.xxl : spacing.xl;
  }
}

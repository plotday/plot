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
    instance = this;
    _loadFromPreferences();
  }

  /// The current instance. Used by platform menu bar commands that run
  /// outside the LayoutBloc provider scope.
  static LayoutBloc? instance;

  double width = 0.0;

  /// When true, prefer middle panel over left when both can't fit.
  /// Set by thread commands so resize transitions preserve thread context.
  bool preferMiddle = false;

  /// Handlers the active page header registers so the mobile bottom-nav
  /// can toggle or close the contextual search on whatever page is
  /// currently visible. Null when no page with search is mounted.
  VoidCallback? _searchToggleHandler;
  VoidCallback? _searchCloseHandler;

  void registerSearchToggle(VoidCallback handler) {
    _searchToggleHandler = handler;
  }

  void unregisterSearchToggle(VoidCallback handler) {
    if (identical(_searchToggleHandler, handler)) {
      _searchToggleHandler = null;
    }
  }

  void registerSearchClose(VoidCallback handler) {
    _searchCloseHandler = handler;
  }

  void unregisterSearchClose(VoidCallback handler) {
    if (identical(_searchCloseHandler, handler)) {
      _searchCloseHandler = null;
    }
  }

  void requestSearchToggle() {
    _searchToggleHandler?.call();
  }

  void requestSearchClose() {
    _searchCloseHandler?.call();
  }

  bool get hasSearchToggle => _searchToggleHandler != null;
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

  void _recalculate({bool explicit = false}) {
    final isMulti = LayoutState.isMultiPanel(width);
    bool effectiveLeftVisible = false;
    bool effectiveMiddleVisible = false;
    if (isMulti) {
      // Multi-panel mode is always 2 (no left sidebar) or 3 (with left
      // sidebar) panels. The middle (priorities feed) is always visible;
      // only the left sidebar toggles. Left needs room for all three.
      effectiveMiddleVisible = true;
      final canShowThree = width >= LayoutState.threePanelMinWidth;
      effectiveLeftVisible = leftPanelRequested && canShowThree;
      if (explicit) {
        leftPanelRequested = effectiveLeftVisible;
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
    final prev = preferMiddle;
    preferMiddle = true;
    _recalculate(explicit: true);
    preferMiddle = prev;
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

/// Extension to access multiPanel state from any context.
extension LayoutHelpers on BuildContext {
  /// Check if current screen width supports multi-panel layout.
  /// Prefers LayoutBloc (uses LayoutBuilder constraints, correct on all browsers).
  /// Falls back to MediaQuery for contexts outside the LayoutBloc scope.
  bool get isMultiPanel {
    final bloc = read<LayoutBloc?>();
    if (bloc != null) return bloc.state.multiPanel;
    return LayoutState.isMultiPanel(MediaQuery.of(this).size.width);
  }

  /// Horizontal content padding — wider on desktop for breathing room.
  double get contentPaddingH {
    final spacing = FTheme.of(this).spacing;
    return isMultiPanel ? spacing.xxl : spacing.xl;
  }
}

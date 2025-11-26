import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/util/theme_color.dart';

part 'theme_state.dart';

/// Theme bloc (cubit) for managing theme/appearance state
class ThemeBloc extends Cubit<ThemeState> {
  ThemeBloc() : super(const ThemeState(mode: AppThemeMode.system)) {
    _loadFromPreferences();
  }

  bool isDarkMode(BuildContext context) =>
      state.mode == AppThemeMode.dark ||
      (state.mode == AppThemeMode.system &&
          MediaQuery.of(context).platformBrightness ==
              material.Brightness.dark);

  Brightness getBrightness(BuildContext context) =>
      isDarkMode(context) ? Brightness.dark : Brightness.light;

  /// Set the theme mode
  void setThemeMode(AppThemeMode mode) {
    emit(state.copyWith(mode: mode));
    _persistState();
  }

  /// Set the priority color for the color scheme
  void setPriorityColor(ThemeColor color) {
    emit(state.copyWith(priorityColor: color));
    _persistState();
  }

  /// Load state from shared preferences
  Future<void> _loadFromPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final modeString = prefs.getString('theme_mode') ?? 'system';
    final mode = AppThemeMode.values.firstWhere(
      (m) => m.name == modeString,
      orElse: () => AppThemeMode.system,
    );
    final colorIndex = prefs.getInt('priority_color') ?? 0;
    emit(state.copyWith(mode: mode, priorityColor: ThemeColor(colorIndex)));
  }

  /// Persist state to shared preferences
  Future<void> _persistState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', state.mode.name);
    await prefs.setInt('priority_color', state.priorityColor.index);
  }
}

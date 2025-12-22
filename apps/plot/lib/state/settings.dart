import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:drift/drift.dart' as drift;

import 'package:plot/store/store.dart';

part 'settings_state.dart';

/// Settings bloc for managing user settings with remote sync
class SettingsBloc extends Cubit<SettingsState> {
  SettingsBloc() : super(const SettingsState()) {
    _init();
  }

  /// Initialize by loading from database and watching for changes
  Future<void> _init() async {
    // Load initial settings
    await _loadFromDatabase();

    // Watch for changes from other devices
    UserSettingsEntity.watch().listen((settings) {
      if (settings != null) {
        _updateFromDatabase(settings);
      }
    });
  }

  /// Load settings from the database
  Future<void> _loadFromDatabase() async {
    final settings = await UserSettingsEntity.get();
    if (settings != null) {
      _updateFromDatabase(settings);
    }
  }

  /// Update state from database row
  void _updateFromDatabase(UserSettingsRow settings) {
    emit(state.copyWith(
      enterBehavior: settings.enterBehavior ?? EnterBehavior.enterSubmits,
      hasBeenPromptedForEnterBehavior: settings.enterBehavior != null,
    ));
  }

  /// Set the enter key behavior
  Future<void> setEnterBehavior(EnterBehavior behavior) async {
    emit(state.copyWith(
      enterBehavior: behavior,
      hasBeenPromptedForEnterBehavior: true,
    ));

    await UserSettingsEntity.save(
      UserSettingsCompanion(
        enterBehavior: drift.Value(behavior),
      ),
    );
  }
}

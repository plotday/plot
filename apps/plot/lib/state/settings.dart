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
    // SettingsBloc is provided at app root and constructed lazily on first
    // watch. If a sign-out fires while a settings-watching widget is still
    // in the tree, that lazy first watch would otherwise crash on
    // [Base.userId] inside [UserSettingsEntity.get]/[watch].
    if (!Base.signedIn) return;

    await _loadFromDatabase();

    UserSettingsEntity.watch().listen((settings) {
      if (settings != null) {
        _updateFromDatabase(settings);
      }
    });
  }

  /// Load settings from the database
  Future<void> _loadFromDatabase() async {
    if (!Base.signedIn) return;
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
      aiEnabled: settings.aiEnabled ?? true,
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

  /// Set whether AI features are enabled
  Future<void> setAiEnabled(bool enabled) async {
    emit(state.copyWith(aiEnabled: enabled));

    await UserSettingsEntity.save(
      UserSettingsCompanion(
        aiEnabled: drift.Value(enabled),
      ),
    );
  }
}

import 'dart:async';

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

  /// Drift watch on the current user's settings row. Held so it can be torn
  /// down and re-bound when a different user signs in on the same device — the
  /// stream is bound to one [Store] (one user's DB) and dies when that Store is
  /// closed on sign-out. See [restart].
  StreamSubscription<UserSettingsRow?>? _watchSub;

  /// Initialize by loading from database and watching for changes
  Future<void> _init() async {
    // SettingsBloc is provided at app root and constructed lazily on first
    // watch. If a sign-out fires while a settings-watching widget is still
    // in the tree, that lazy first watch would otherwise crash on
    // [Base.userId] inside [UserSettingsEntity.get]/[watch].
    if (!Base.signedIn) return;

    await _loadFromDatabase();

    await _watchSub?.cancel();
    _watchSub = UserSettingsEntity.watch().listen((settings) {
      if (settings != null) {
        _updateFromDatabase(settings);
      }
    });
  }

  /// Re-bind to the current user's settings after a sign-out → sign-in on the
  /// same device. This bloc lives at the app root and isn't recreated per user,
  /// and its [_watchSub] is bound to the previous user's now-closed [Store], so
  /// without this it would keep showing the previous user's enter-behavior / AI
  /// setting. Called from the re-sign-in path in `root_provider`.
  Future<void> restart() async {
    await _watchSub?.cancel();
    _watchSub = null;
    emit(const SettingsState());
    await _init();
  }

  @override
  Future<void> close() {
    _watchSub?.cancel();
    return super.close();
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

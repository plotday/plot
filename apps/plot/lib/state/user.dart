import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';
import 'logging.dart';

part 'user_state.dart';

class UserBloc extends Cubit<UserState> {
  UserBloc() : super(const UserLoading()) {
    _userSubscription = Base.user.listen((user) async {
      if (user == null) {
        if (state is UserSignedOut) return;
        log.info('User signed out');
        await _clearPasswordSetupRequired();
        emit(const UserSignedOut());
        log.info('Sign out state emitted');
        return;
      } else if (_passwordSetupRequired) {
        if (state is UserPasswordRequired) return;
        log.info('User requires password setup: ${user.primaryEmail}');
        emit(UserPasswordRequired(user));
        return;
      } else if (!user.isActive) {
        if (state is UserWaitlisted) return;
        // The user may have been activated by a database trigger (e.g. invitation
        // acceptance) after the JWT was issued. Refresh the session to pick up
        // any status changes before showing the invitation screen.
        try {
          final refreshed = await Base.refreshSession();
          final refreshedUser = refreshed.user != null
              ? User(refreshed.user!)
              : null;
          if (refreshedUser != null && refreshedUser.isActive) {
            log.info(
                'User activated after session refresh: ${refreshedUser.primaryEmail}');
            // The refreshed session will trigger another event on Base.user,
            // which will be handled by the normal active-user path above.
            return;
          }
        } catch (e) {
          log.warning('Session refresh failed during waitlist check: $e');
        }
        log.info('User signed in but waitlisted: ${user.primaryEmail}');
        emit(UserWaitlisted(user));
        return;
      } else if (state is UserReady) {
        return;
      }

      log.info('User signed in: ${user.primaryEmail}');
      await Store.start(user);
      // Ensure Actor cache is populated before app becomes interactive
      await Actor.pullCritical();
      emit(UserReady(user));
    });
  }

  late final StreamSubscription<User?>? _userSubscription;
  bool _passwordSetupRequired = false;

  static const String _kPasswordSetupRequiredKey = 'password_setup_required';

  /// Sets whether password setup is required and updates state accordingly
  Future<void> setPasswordSetupRequired(bool required) async {
    _passwordSetupRequired = required;
    final prefs = ProfilePreferences.instance;
    if (required) {
      await prefs.setBool(_kPasswordSetupRequiredKey, true);
    } else {
      await prefs.remove(_kPasswordSetupRequiredKey);
    }

    // Re-emit state based on current user and new flag
    final currentUser = await Base.user.first;
    if (currentUser != null) {
      if (!currentUser.isActive) {
        emit(UserWaitlisted(currentUser));
      } else if (_passwordSetupRequired) {
        emit(UserPasswordRequired(currentUser));
      } else if (state is! UserReady) {
        await Store.start(currentUser);
        // Ensure Actor cache is populated before app becomes interactive
        await Actor.pullCritical();
        emit(UserReady(currentUser));
      }
    }
  }

  /// Clears the password setup required flag (called on sign-out or non-OTP sign-in)
  Future<void> clearPasswordSetupRequired() async {
    await _clearPasswordSetupRequired();
  }

  Future<void> _clearPasswordSetupRequired() async {
    _passwordSetupRequired = false;
    final prefs = ProfilePreferences.instance;
    await prefs.remove(_kPasswordSetupRequiredKey);
  }

  @override
  Future<void> close() async {
    _userSubscription?.cancel();
    await super.close();
  }
}

import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/api/api.dart' as api;
import 'package:plot/store/store.dart';
import 'logging.dart';

part 'user_state.dart';

class UserBloc extends Cubit<UserState> {
  UserBloc() : super(const UserLoading()) {
    _userSubscription = Base.user.listen((user) async {
      if (user == null) {
        if (state is UserSignedOut) return;
        log.info('User signed out');
        emit(const UserSignedOut());
        log.info('Sign out state emitted');
        return;
      } else if (state is UserReady) {
        return;
      }

      log.info('User signed in: ${user.primaryEmail}');

      // Only call /activate for fresh sign-ins (not restored from local storage)
      // to ensure account setup (Stripe, twist, etc.) is complete.
      if (Base.isFreshSignIn) {
        try {
          await api.post<Map<String, dynamic>>('/activate');
        } catch (e) {
          log.warning('Account setup call failed (non-blocking): $e');
        }
      }

      await Store.start(user);
      // Ensure Actor cache is populated before app becomes interactive
      await Actor.pullCritical();
      emit(UserReady(user));
    });
  }

  late final StreamSubscription<User?>? _userSubscription;

  @override
  Future<void> close() async {
    _userSubscription?.cancel();
    await super.close();
  }
}

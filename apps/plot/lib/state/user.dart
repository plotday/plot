import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

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
      } else {
        if (state is UserReady) return;
        log.info('User signed in: ${user.primaryEmail}');
        try {
          await Store.init(user);
          emit(UserReady(user));
          Base.client.auth.refreshSession();
        } catch (e, stackTrace) {
          log.warning('User init failed', e, stackTrace);
          emit(const UserSignedOut());
        }
      }
    });
  }

  late final StreamSubscription<User?>? _userSubscription;

  @override
  Future<void> close() async {
    _userSubscription?.cancel();
    await super.close();
  }
}

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/base.dart';
import 'package:plot/store/store.dart';
import 'logging.dart';

part 'user_state.dart';

class UserBloc extends Cubit<UserState> {
  UserBloc() : super(const UserLoading()) {
    Base.client.auth.refreshSession();
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
          await Store.get.sync();
          emit(UserReady(user));
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

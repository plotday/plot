import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/base.dart';
import 'package:plot/store/store.dart';

part 'user_state.dart';

class UserBloc extends Cubit<UserState> {
  UserBloc() : super(const UserLoading()) {
    _userSubscription = Base.user.listen((user) async {
      if (user == null) {
        emit(const UserSignedOut());
      } else {
        try {
          await Store.init(user);
          await Store.get.sync();
          emit(UserReady(user));
        } catch (e, stackTrace) {
          print(e);
          print(stackTrace);
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

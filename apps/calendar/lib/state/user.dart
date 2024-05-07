import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/model/user.dart';

part 'user_state.dart';

class UserBloc extends Cubit<UserState> {
  UserBloc() : super(const UserLoading()) {
    _userSubscription = User.onCurrent.listen((user) {
      if (user == null) {
        emit(const UserSignedOut());
      } else {
        emit(UserSignedIn(user));
      }
    });
  }

  late final StreamSubscription<User?> _userSubscription;

  @override
  Future<void> close() async {
    _userSubscription.cancel();
    await super.close();
  }
}

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:plot/base.dart' hide User;
import 'package:plot/base.dart' as base_user show User;
import 'package:sentry_flutter/sentry_flutter.dart';

part 'user_state.dart';

class User extends Equatable {
  const User(this._baseUser);

  String get id => _baseUser.id;
  String? get primaryEmail => _baseUser.email;

  /* private */

  final base_user.User _baseUser;

  @override
  List<Object> get props => [_baseUser.id];
}

class UserBloc extends Cubit<UserState> {
  UserBloc() : super(const UserLoading()) {
    // TODO store user and handle offline
    _authSubscription = Base.client.auth.onAuthStateChange.listen((data) {
      if (data.session?.user == null) {
        emit(const UserSignedOut());
        Sentry.configureScope((scope) => scope.setUser(null));
        return;
      }
      final user = User(data.session!.user);

      emit(UserSignedIn(user));
      Sentry.configureScope(
        (scope) => scope.setUser(SentryUser(
          id: user.id,
          email: user.primaryEmail,
        )),
      );
    });
  }

  late final StreamSubscription<AuthState>? _authSubscription;

  @override
  Future<void> close() async {
    _authSubscription?.cancel();
    await super.close();
  }
}

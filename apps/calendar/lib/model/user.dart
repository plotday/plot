import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:plot/base.dart' hide User;
import 'package:plot/base.dart' as base_user show User;

class User extends Equatable {
  static User? get current => _current;

  static Stream<User?> get onCurrent {
    _init();
    return _userStreamController.stream;
  }

  const User(this._baseUser);

  String get id => _baseUser.id;
  String? get primaryEmail => _baseUser.email;

  /* private static */

  static void _init() {
    if (_authSubscription != null) return;
    _authSubscription = base.auth.onAuthStateChange.listen((data) {
      if (data.session?.user == null) {
        _current = null;
      } else {
        _current = User(data.session!.user);
      }
      Sentry.configureScope(
        (scope) => scope.setUser(_current == null
            ? null
            : SentryUser(
                id: _current!.id,
                email: _current!.primaryEmail,
              )),
      );
      _userStreamController.add(_current);
    });
  }

  static final StreamController<User?> _userStreamController =
      StreamController<User?>.broadcast();
  static StreamSubscription<AuthState>? _authSubscription;
  static User? _current;

  /* private */

  final base_user.User _baseUser;

  @override
  List<Object> get props => [_baseUser.id];
}

import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:injector/injector.dart';
import 'package:rxdart/rxdart.dart';

import 'package:supabase_flutter/supabase_flutter.dart' as supa;
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'package:plot/util/uuid.dart';
import 'env.dart';

class User extends Equatable {
  const User(this._baseUser);

  String get id => _baseUser.id;
  String? get primaryEmail => _baseUser.email;
  String? get name => _baseUser.userMetadata?['full_name'] as String?;

  /* private */

  final supa.User _baseUser;

  @override
  List<Object> get props => [_baseUser.id];
}

// TODO store user and handle offline
class Base {
  static supa.SupabaseClient get client =>
      Injector.appInstance.get<Base>()._client!;
  static Stream<User?> get user =>
      Injector.appInstance.get<Base>()._currentUserController.stream;
  static bool get signedIn => Injector.appInstance.get<Base>()._userId != null;
  static Uuid get userId => Injector.appInstance.get<Base>()._userId!;

  static Future<void> init() async {
    await supa.Supabase.initialize(
      url: Env.supabaseUrl,
      anonKey: Env.supabaseAnonKey,
    );
    Injector.appInstance.registerSingleton<Base>(() => Base());
  }

  Base()
      : _client = supa.Supabase.instance.client,
        _userId = null {
    _client!.auth.onAuthStateChange.listen((data) async {
      User? user;
      if (data.session?.user == null) {
        await Sentry.configureScope((scope) => scope.setUser(null));
        await Posthog().flush();
        await Posthog().reset();
      } else {
        user = User(data.session!.user);
        await Sentry.configureScope(
          (scope) => scope.setUser(SentryUser(
            id: user!.id,
            email: user.primaryEmail,
          )),
        );
        await Posthog().identify(userId: user.id, userProperties: {
          ...(user.primaryEmail == null ? {} : {"email": user.primaryEmail!}),
          ...(user.name == null ? {} : {"name": user.name!}),
        }, userPropertiesSetOnce: {
          "signed_up_time": DateTime.now().toUtc().toIso8601String(),
        });
      }
      _userId = user == null ? null : Uuid.fromString(user.id);
      _currentUserController.add(user);
    });
  }

  Base.disconnected()
      : _client = null,
        _userId = Uuid.generate() {
    _currentUserController.add(null);
  }

  final supa.SupabaseClient? _client;
  Uuid? _userId;
  final _currentUserController = BehaviorSubject<User?>();

  // Dispose of the StreamController
  void dispose() {
    _currentUserController.close();
  }
}

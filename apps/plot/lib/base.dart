import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:injector/injector.dart';
import 'package:rxdart/rxdart.dart';

import 'package:supabase_flutter/supabase_flutter.dart' as supa;
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/analytics/analytics.dart';
import 'env.dart';
import 'logging.dart';

class User extends Equatable {
  const User(this._baseUser);

  String get id => _baseUser.id;
  String? get primaryEmail => _baseUser.email;
  String? get name => _baseUser.userMetadata?['full_name'] as String?;
  String? get status => _baseUser.appMetadata['status'] as String?;
  bool get isActive => status == 'active';

  /* private */

  final supa.User _baseUser;

  @override
  List<Object> get props => [_baseUser.id];
}

class Base {
  static supa.SupabaseClient get client =>
      Injector.appInstance.get<Base>()._client!;
  static Stream<User?> get user =>
      Injector.appInstance.get<Base>()._currentUserController.stream;
  static bool get signedIn => Injector.appInstance.get<Base>()._userId != null;
  static Uuid get userId => Injector.appInstance.get<Base>()._userId!;

  static Future<void> init() async {
    try {
      log.info("Initializing Supabase (${Env.supabaseUrl})");
      await supa.Supabase.initialize(
        url: Env.supabaseUrl,
        anonKey: Env.supabaseAnonKey,
      );
      Injector.appInstance.registerSingleton<Base>(() => Base());
      log.info("Supabase ready");
    } catch (e, stack) {
      log.warning("Supabase errore", e, stack);
    }
  }

  static Future<void> refreshSession() async {
    await client.auth.refreshSession();
  }

  Base() : _client = supa.Supabase.instance.client, _userId = null {
    _client!.auth.onAuthStateChange.listen((data) async {
      await _updateUser(data.session?.user);
    });
  }

  final supa.SupabaseClient? _client;
  bool _initialized = false;
  Uuid? _userId;
  DateTime? _signInTime;
  final _currentUserController = BehaviorSubject<User?>();

  // Dispose of the StreamController
  void dispose() {
    _currentUserController.close();
  }

  Future<void> _updateUser(supa.User? supaUser) async {
    final currentUser = _currentUserController.valueOrNull;
    final newUser = supaUser == null ? null : User(supaUser);

    // Skip if user hasn't changed (same ID and status)
    if (_initialized &&
        currentUser?.id == newUser?.id &&
        currentUser?.status == newUser?.status) {
      return;
    }

    User? user = supaUser == null ? null : User(supaUser);
    _userId = user == null ? null : Uuid.fromString(user.id);
    _initialized = true;
    if (user == null) {
      // User signing out
      await Sentry.configureScope((scope) => scope.setUser(null));

      // Track sign out event with session duration
      if (_signInTime != null) {
        final sessionDurationMs =
            DateTime.now().difference(_signInTime!).inMilliseconds;
        await Analytics.instance.trackSession(
          EventAction.signedOut,
          {
            PropertyKey.sessionDurationMs: sessionDurationMs,
          },
        );
      } else {
        await Analytics.instance.trackSession(EventAction.signedOut);
      }

      await Posthog().flush();
      await Posthog().reset();
      _signInTime = null;
    } else {
      // User signing in
      await Sentry.configureScope(
        (scope) =>
            scope.setUser(SentryUser(id: user.id, email: user.primaryEmail)),
      );
      await Posthog().identify(
        userId: user.id,
        userProperties: {
          ...(user.primaryEmail == null ? {} : {"email": user.primaryEmail!}),
          ...(user.name == null ? {} : {"name": user.name!}),
        },
        userPropertiesSetOnce: {
          "signed_up_time": DateTime.now().toUtc().toIso8601String(),
        },
      );

      // Track sign in event
      _signInTime = DateTime.now();
      await Analytics.instance.trackSession(EventAction.signedIn);
    }
    _currentUserController.add(user);
  }
}

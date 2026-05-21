import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/store.dart';
import 'logging.dart';

part 'user_state.dart';

class UserBloc extends Cubit<UserState> {
  /// Status message shown on the loading page during sign-in.
  static final ValueNotifier<String?> statusNotifier = ValueNotifier(null);

  UserBloc() : super(const UserLoading()) {
    _userSubscription = Base.user.listen(_enqueue);
  }

  late final StreamSubscription<User?>? _userSubscription;

  /// Set while [_process] is running. Concurrent emissions on Base.user
  /// (e.g. background /activate completes during the initial Store.start)
  /// are queued in [_pending] and drained when the current run finishes.
  bool _processing = false;
  User? _pending;
  bool _pendingSet = false;

  void _enqueue(User? user) {
    if (_processing) {
      _pending = user;
      _pendingSet = true;
      return;
    }
    unawaited(_drain(user));
  }

  Future<void> _drain(User? user) async {
    _processing = true;
    try {
      await _process(user);
      while (_pendingSet) {
        final next = _pending;
        _pending = null;
        _pendingSet = false;
        await _process(next);
      }
    } finally {
      _processing = false;
    }
  }

  Future<void> _process(User? user) async {
    if (user == null) {
      if (state is UserSignedOut) return;
      log.info('User signed out');
      statusNotifier.value = null;
      emit(const UserSignedOut());
      log.info('Sign out state emitted');
      return;
    } else if (state is UserReady) {
      final current = (state as UserReady).user;
      if (current.id == user.id) {
        return;
      }
      // Different user.id (e.g. background /activate after a server-side
      // DB reset returned a fresh uuid). Fall through to re-run setup so
      // Store.start() tears down the old SQLite DB and opens a new one
      // under the new identity.
      log.info(
        'User id changed (${current.id} → ${user.id}); '
        'restarting Store under new identity',
      );
    }

    log.info('User signed in: ${user.primaryEmail}');
    emit(const UserLoading());
    final stopwatch = Stopwatch()..start();

    try {
      await Future(() async {
        statusNotifier.value = 'Signing in...';
        Store.onStartStatus = (status) => statusNotifier.value = status;
        await Store.start(user);
        Store.onStartStatus = null;
        // If sign-out was triggered during Store.start (e.g. invalid
        // session after migration reset), skip remaining setup.
        if (state is UserSignedOut) return;
        log.info('Store.start completed in ${stopwatch.elapsedMilliseconds}ms');

        statusNotifier.value = 'Almost ready...';
        try {
          // Ensure Actor cache is populated before app becomes interactive
          await Actor.pullCritical();
        } catch (e, stackTrace) {
          log.warning('Actor.pullCritical failed — continuing with local data', e, stackTrace);
        }
        log.info('Post-auth setup completed in ${stopwatch.elapsedMilliseconds}ms');
      }).timeout(const Duration(seconds: 90));
    } on TimeoutException {
      // Soft deadline: Store.start or Actor.pullCritical didn't finish in 90s.
      // Don't sign the user out — their session is valid; sync is just slow.
      // The abandoned future keeps running (Dart .timeout() doesn't cancel),
      // so background work continues and the UI fills in as data arrives.
      // The inner 30s new-user critical-sync timeout is swallowed in
      // Store.start, so reaching this handler means the whole post-auth
      // setup genuinely exceeded 90s — not just the critical phase.
      log.warning(
        'Post-auth setup exceeded 90s — proceeding with partial state; background sync will continue',
      );
      Tracker.trackError(
        'auth',
        errorType: 'TimeoutException',
        errorMessage: 'Post-auth setup exceeded 90s (non-fatal)',
        context: 'sign_in_setup_timeout',
      );
      // Fall through to emit UserReady below.
    } catch (e, stackTrace) {
      log.warning('Store.start failed — cannot proceed', e, stackTrace);
      Tracker.trackError(
        'auth',
        errorType: e.runtimeType.toString(),
        errorMessage: e.toString(),
        stackTrace: stackTrace.toString(),
        context: 'sign_in_store_start_failed',
      );
      statusNotifier.value = null;
      try { await Base.signOut(); } catch (_) {}
      emit(const UserSignedOut());
      return;
    }

    statusNotifier.value = null;
    // Don't emit UserReady if sign-out was triggered during setup
    if (state is UserSignedOut) return;
    emit(UserReady(user));
  }

  @override
  Future<void> close() async {
    _userSubscription?.cancel();
    await super.close();
  }
}

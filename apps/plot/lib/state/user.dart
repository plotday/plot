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
    _userSubscription = Base.user.listen((user) async {
      if (user == null) {
        if (state is UserSignedOut) return;
        log.info('User signed out');
        statusNotifier.value = null;
        emit(const UserSignedOut());
        log.info('Sign out state emitted');
        return;
      } else if (state is UserReady) {
        return;
      }

      log.info('User signed in: ${user.primaryEmail}');
      final stopwatch = Stopwatch()..start();

      try {
        await Future(() async {
          statusNotifier.value = 'Signing in...';
          Store.onStartStatus = (status) => statusNotifier.value = status;
          await Store.start(user);
          Store.onStartStatus = null;
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
        log.warning('Post-auth setup timed out after 90s — signing out');
        Tracker.trackError(
          'auth',
          errorType: 'TimeoutException',
          errorMessage: 'Post-auth setup timed out after 90s',
          context: 'sign_in_setup_timeout',
        );
        statusNotifier.value = null;
        emit(const UserSignedOut());
        return;
      } catch (e, stackTrace) {
        log.warning('Store.start failed — cannot proceed', e, stackTrace);
        statusNotifier.value = null;
        emit(const UserSignedOut());
        return;
      }

      statusNotifier.value = null;
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

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/auth_button.dart' show runWithPopupSpinnerGrace;

/// Regression tests for the OAuth popup spinner grace period.
///
/// FlutterWebAuth2 exposes no "popup is visible" signal, and the popup can take
/// several seconds to actually appear (notably LinkedIn/Unipile hosted auth).
/// Previously the auth button dropped its spinner the instant we called
/// authenticate(), so the button looked idle while the user was still waiting
/// for the popup to show — confusing. [runWithPopupSpinnerGrace] keeps the
/// spinner on for a grace period after launch, then drops it (so the button
/// doesn't look stuck for a user who closed/abandoned the popup, since on web
/// authenticate() won't resolve until the callback arrives or its ~5-min
/// timeout fires).
void main() {
  group('runWithPopupSpinnerGrace', () {
    test(
        'keeps the spinner on until the grace elapses while auth is pending, '
        'then drops it', () {
      fakeAsync((async) {
        var dropped = 0;
        final pending = Completer<String>();

        unawaited(runWithPopupSpinnerGrace<String>(
          authenticate: () => pending.future,
          dropSpinner: () => dropped++,
          grace: const Duration(seconds: 4),
        ));

        // Before the grace elapses, the spinner stays on (popup may still be
        // appearing) — this is the whole point of the fix.
        async.elapse(const Duration(seconds: 3));
        expect(dropped, 0);

        // Once the grace elapses, drop the spinner so an abandoned popup
        // doesn't leave the button looking stuck.
        async.elapse(const Duration(seconds: 2));
        expect(dropped, 1);

        pending.complete('ok');
        async.flushMicrotasks();
      });
    });

    test('never drops the spinner when auth completes before the grace', () {
      fakeAsync((async) {
        var dropped = 0;

        unawaited(runWithPopupSpinnerGrace<String>(
          authenticate: () async => 'ok',
          dropSpinner: () => dropped++,
          grace: const Duration(seconds: 4),
        ));

        // Auth resolves on a microtask; advancing well past the grace must not
        // fire the (cancelled) timer.
        async.elapse(const Duration(seconds: 10));
        expect(dropped, 0);
      });
    });

    test('cancels the grace timer once auth settles (no late drop)', () {
      fakeAsync((async) {
        var dropped = 0;
        final completer = Completer<String>();

        unawaited(runWithPopupSpinnerGrace<String>(
          authenticate: () => completer.future,
          dropSpinner: () => dropped++,
          grace: const Duration(seconds: 4),
        ));

        // Auth finishes well before the grace.
        async.elapse(const Duration(seconds: 1));
        completer.complete('ok');
        async.flushMicrotasks();
        expect(dropped, 0);

        // Advancing past the original grace must not fire the cancelled timer.
        async.elapse(const Duration(seconds: 10));
        expect(dropped, 0);
      });
    });

    test('returns the auth result', () async {
      final result = await runWithPopupSpinnerGrace<String>(
        authenticate: () async => 'token',
        dropSpinner: () {},
        grace: const Duration(seconds: 4),
      );
      expect(result, 'token');
    });

    test('propagates auth errors and cancels the grace timer', () {
      fakeAsync((async) {
        var dropped = 0;
        Object? caught;

        runWithPopupSpinnerGrace<String>(
          authenticate: () async => throw StateError('boom'),
          dropSpinner: () => dropped++,
          grace: const Duration(seconds: 4),
        ).catchError((Object e) {
          caught = e;
          return '';
        });

        async.elapse(const Duration(seconds: 10));
        expect(caught, isA<StateError>());
        // Threw before the grace → timer cancelled, spinner never dropped here
        // (the caller's finally restores button state).
        expect(dropped, 0);
      });
    });
  });
}

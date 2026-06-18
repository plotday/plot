import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/post_auth_navigation_gate.dart';

void main() {
  group('PostAuthNavigationGate', () {
    test('cold start / refresh: first ready does NOT navigate to default', () {
      // App boots already signed in (web page refresh or deep-link open).
      // No UserSignedOut is ever observed, so the router's already-resolved
      // URL (e.g. /p/<focus> or /t/<thread>) must be left alone.
      final gate = PostAuthNavigationGate();
      expect(gate.shouldNavigateToDefaultOnReady(), isFalse);
    });

    test('re-sign-in: ready after a sign-out DOES navigate to default', () {
      final gate = PostAuthNavigationGate();
      gate.onSignedOut();
      expect(gate.shouldNavigateToDefaultOnReady(), isTrue);
    });

    test('re-sign-in flag is consumed: a later ready without another '
        'sign-out does NOT navigate (e.g. background identity refresh)', () {
      final gate = PostAuthNavigationGate();
      gate.onSignedOut();
      expect(gate.shouldNavigateToDefaultOnReady(), isTrue);
      // Second ready with no intervening sign-out: leave route alone.
      expect(gate.shouldNavigateToDefaultOnReady(), isFalse);
    });

    test('multiple sign-outs before a ready still navigate exactly once', () {
      final gate = PostAuthNavigationGate();
      gate.onSignedOut();
      gate.onSignedOut();
      expect(gate.shouldNavigateToDefaultOnReady(), isTrue);
      expect(gate.shouldNavigateToDefaultOnReady(), isFalse);
    });

    test('repeated full re-sign-in cycles each navigate once', () {
      final gate = PostAuthNavigationGate();
      // Cold start.
      expect(gate.shouldNavigateToDefaultOnReady(), isFalse);
      // Sign out then back in.
      gate.onSignedOut();
      expect(gate.shouldNavigateToDefaultOnReady(), isTrue);
      // Sign out then back in again.
      gate.onSignedOut();
      expect(gate.shouldNavigateToDefaultOnReady(), isTrue);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:plot/base.dart' show Base;

/// Regression for "signing out leaves the user signed in".
///
/// An identity resolution (`/activate`) is asynchronous. If an explicit
/// `signOut()` runs while one is in flight, its result must NOT be applied —
/// otherwise `setIdentity()` re-persists the identity and re-emits the user
/// over the top of `UserSignedOut`, resurrecting a session whose Clerk auth
/// was just revoked. The app then looks "signed in" while every API call 401s
/// (server reconcile: "no active session") in a forced-re-auth loop.
///
/// `Base.signOut()` advances an auth epoch; each resolution snapshots the
/// epoch before its round-trip and `setIdentity()` discards the result when
/// the snapshot is stale. [Base.authEpochSuperseded] is the shared decision
/// used by every guard, so it pins the contract.
void main() {
  group('Base.authEpochSuperseded', () {
    test('no sign-out during resolution (epoch unchanged) → apply identity', () {
      expect(Base.authEpochSuperseded(3, 3), isFalse);
    });

    test('sign-out advanced the epoch mid-flight → discard identity', () {
      // Resolution captured epoch 0; signOut() bumped it to 1 before the
      // /activate response arrived. The stale result must be dropped.
      expect(Base.authEpochSuperseded(0, 1), isTrue);
    });

    test('two sign-outs during a slow resolution still discard', () {
      expect(Base.authEpochSuperseded(2, 4), isTrue);
    });

    test('null captured epoch opts out of the check (non-racing callers)', () {
      expect(Base.authEpochSuperseded(null, 7), isFalse);
    });
  });

  group('Base.shouldDiscardIdentity', () {
    test('not signed out, epoch unchanged → restore identity', () {
      expect(Base.shouldDiscardIdentity(false, 3, 3), isFalse);
    });

    test('sign-out latch set → discard even when the epoch still matches', () {
      // The residual bug: a background resolution that STARTS during sign-out
      // snapshots the already-bumped epoch (so the epoch check passes) but the
      // latch still blocks it. Without the latch this resurrected the session
      // and produced the 401 storm before forced re-auth bounced it back out.
      expect(Base.shouldDiscardIdentity(true, 5, 5), isTrue);
    });

    test('sign-out advanced the epoch mid-flight → discard (latch clear)', () {
      // e.g. an old resolution for a previous account completing after the
      // user signed out and back in as someone else.
      expect(Base.shouldDiscardIdentity(false, 0, 1), isTrue);
    });

    test('explicit sign-in lifted the latch, fresh epoch → restore', () {
      expect(Base.shouldDiscardIdentity(false, 2, 2), isFalse);
    });
  });
}

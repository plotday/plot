import 'package:flutter_test/flutter_test.dart';

import 'package:plot/store/store.dart';

/// Regression test for: a "Reconnect LinkedIn" prompt that never goes away.
///
/// A connection can carry `needs_reauth_at` while all of its channels are
/// disabled (the user turned syncing off instead of reconnecting). The
/// manage-connections modal hides such a connection (`enabledCount == 0`) and
/// the server excludes it from quota counts — yet the sidebar status tile and
/// the manage-connections command icon used to keep nagging "Reconnect …"
/// forever because they only looked at `needsReauth`.
///
/// [TwistConnection.active] is the shared filter both surfaces now apply: a
/// connection drives the prompts only when its instance still has an enabled
/// channel. These tests cover that filter directly (no widget tree / Drift, so
/// no flaky async).
TwistConnectionRow _conn(Uuid instanceId, {required bool needsReauth}) =>
    TwistConnectionRow(
      updatedAt: DateTime(2026),
      twistInstanceId: instanceId,
      provider: 'linkedin',
      actorId: 'actor-1',
      needsReauth: needsReauth,
      initialSyncing: false,
    );

void main() {
  final stuck = Uuid.generate(); // needs re-auth, but all channels disabled
  final live = Uuid.generate(); // needs re-auth, has an enabled channel

  test('a connection with no enabled channel is not active', () {
    final connections = [
      _conn(stuck, needsReauth: true),
      _conn(live, needsReauth: true),
    ];

    // Only `live` has an enabled channel.
    final active = TwistConnection.active(connections, {live}).toList();

    expect(active.map((c) => c.twistInstanceId), [live]);
    // The reconnect prompt is derived from active connections needing re-auth,
    // so the stuck connection is excluded and only `live` would nag.
    expect(
      active.where((c) => c.needsReauth).map((c) => c.twistInstanceId),
      [live],
    );
  });

  test('no active connections when every channel is disabled', () {
    final connections = [_conn(stuck, needsReauth: true)];

    final active = TwistConnection.active(connections, <TwistInstanceId>{});

    expect(active, isEmpty,
        reason: 'a connection whose channels are all disabled must not drive '
            'the reconnect prompt');
  });

  group('anyActiveNeedsReauth', () {
    test('true when an active (enabled-channel) connection needs re-auth', () {
      final connections = [_conn(live, needsReauth: true)];

      expect(TwistConnection.anyActiveNeedsReauth(connections, {live}), isTrue);
    });

    test('false when the only connection needing re-auth is dormant', () {
      // Regression for the More-tab badge: a connection with `needs_reauth_at`
      // set but all channels disabled (e.g. a stale LinkedIn instance left
      // behind by a reconnect-without-archive) is hidden from the connections
      // list, so it must not light the red badge — there is no row to act on.
      final connections = [_conn(stuck, needsReauth: true)];

      expect(
        TwistConnection.anyActiveNeedsReauth(connections, {live}),
        isFalse,
        reason: 'a dormant connection (no enabled channel) must not light the '
            'reconnect badge',
      );
    });

    test('false when active connections are all healthy', () {
      final connections = [_conn(live, needsReauth: false)];

      expect(TwistConnection.anyActiveNeedsReauth(connections, {live}), isFalse);
    });

    test('ignores a stuck dormant connection alongside a healthy active one', () {
      final connections = [
        _conn(stuck, needsReauth: true), // dormant — must be ignored
        _conn(live, needsReauth: false), // active and healthy
      ];

      expect(
        TwistConnection.anyActiveNeedsReauth(connections, {live}),
        isFalse,
      );
    });
  });
}

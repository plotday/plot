import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

ThreadRow _row({bool statePending = true}) => ThreadRow(
      id: Uuid.generate(),
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      priorityId: Uuid.generate(),
      draft: false,
      unread: false,
      importance: 0,
      active: false,
      hasEmbedding: false,
      revoked: false,
      statePending: statePending,
    );

void main() {
  group('ThreadsBase wire mapping for state_pending', () {
    test('toBase strips the client-only state_pending marker', () {
      final json = ThreadsBase().toBase(_row(statePending: true));
      expect(
        json.containsKey('state_pending'),
        isFalse,
        reason: 'state_pending must never reach the /sync/threads endpoint',
      );
    });

    test('fromBase defaults state_pending to false (server never sends it)',
        () {
      final serverJson = _row(statePending: true).toJson()
        ..remove('state_pending');
      expect(serverJson.containsKey('state_pending'), isFalse);

      final result = ThreadsBase().fromBase(serverJson) as ThreadRow;

      expect(
        result.statePending,
        isFalse,
        reason: 'a pulled row must not arrive already-dirty',
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:plot/state/move_recency.dart';
import 'package:plot/store/store.dart';

void main() {
  group('MoveRecency', () {
    setUp(() => MoveRecency.instance.clear());
    tearDown(() => MoveRecency.instance.clear());

    test('record prepends newest-first and dedupes', () {
      final r = MoveRecency.instance;
      final a = Uuid.generate();
      final b = Uuid.generate();

      r.record(a);
      r.record(b);
      expect(r.recent, [b, a], reason: 'newest move comes first');

      r.record(a); // move into `a` again
      expect(r.recent, [a, b], reason: 'a returns to front, no duplicate');
    });

    test('recent is unmodifiable', () {
      final r = MoveRecency.instance;
      r.record(Uuid.generate());
      expect(() => r.recent.add(Uuid.generate()), throwsUnsupportedError);
    });

    test('clear empties the list', () {
      final r = MoveRecency.instance;
      r.record(Uuid.generate());
      r.clear();
      expect(r.recent, isEmpty);
    });
  });
}

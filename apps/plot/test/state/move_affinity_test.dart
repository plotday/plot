import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/move_recency.dart';
import 'package:plot/util/uuid.dart';

void main() {
  group('MoveAffinity', () {
    test('fromMap tolerates null / empty / malformed → empty', () {
      expect(MoveAffinity.fromMap(null).destsFor(Uuid.generate()), isEmpty);
      expect(MoveAffinity.fromMap(<String, dynamic>{}).destsFor(Uuid.generate()),
          isEmpty);
      // Malformed nested value: not a map → ignored, no throw.
      final s = Uuid.generate();
      final a = MoveAffinity.fromMap({s.toString(): 'garbage'});
      expect(a.destsFor(s), isEmpty);
    });

    test('destsFor returns destinations newest-first', () {
      final s = Uuid.generate();
      final older = Uuid.generate();
      final newer = Uuid.generate();
      final a = MoveAffinity.fromMap({
        s.toString(): {
          older.toString(): 100,
          newer.toString(): 200,
        },
      });
      expect(a.destsFor(s).map((u) => u.toString()),
          [newer.toString(), older.toString()]);
    });

    test('destsFor is scoped to the source (other sources excluded)', () {
      final s1 = Uuid.generate();
      final s2 = Uuid.generate();
      final d1 = Uuid.generate();
      final d2 = Uuid.generate();
      final a = MoveAffinity.fromMap({
        s1.toString(): {d1.toString(): 100},
        s2.toString(): {d2.toString(): 100},
      });
      expect(a.destsFor(s1).map((u) => u.toString()), [d1.toString()]);
      expect(a.destsFor(s2).map((u) => u.toString()), [d2.toString()]);
    });

    test('recordMove adds a new cell and moves it to the front', () {
      final s = Uuid.generate();
      final d1 = Uuid.generate();
      final d2 = Uuid.generate();
      var a = MoveAffinity.fromMap(null);
      a = a.recordMove(s, d1, DateTime.fromMillisecondsSinceEpoch(100));
      a = a.recordMove(s, d2, DateTime.fromMillisecondsSinceEpoch(200));
      expect(a.destsFor(s).map((u) => u.toString()),
          [d2.toString(), d1.toString()]);
    });

    test('recordMove updates an existing cell timestamp (re-floats it)', () {
      final s = Uuid.generate();
      final d1 = Uuid.generate();
      final d2 = Uuid.generate();
      var a = MoveAffinity.fromMap(null)
          .recordMove(s, d1, DateTime.fromMillisecondsSinceEpoch(100))
          .recordMove(s, d2, DateTime.fromMillisecondsSinceEpoch(200));
      // Re-move d1 with a newer time → d1 floats above d2.
      a = a.recordMove(s, d1, DateTime.fromMillisecondsSinceEpoch(300));
      expect(a.destsFor(s).map((u) => u.toString()),
          [d1.toString(), d2.toString()]);
    });

    test('recordMove caps a source to maxPerSource newest destinations', () {
      final s = Uuid.generate();
      var a = MoveAffinity.fromMap(null);
      final dests = <Uuid>[];
      for (var i = 0; i < MoveAffinity.maxPerSource + 3; i++) {
        final d = Uuid.generate();
        dests.add(d);
        a = a.recordMove(s, d, DateTime.fromMillisecondsSinceEpoch(1000 + i));
      }
      final result = a.destsFor(s);
      expect(result.length, MoveAffinity.maxPerSource);
      // The 3 oldest were dropped; the newest survive, newest-first.
      expect(result.first.toString(), dests.last.toString());
      expect(result.map((u) => u.toString()),
          isNot(contains(dests.first.toString())));
    });

    test('destsFor caps at maxPerSource even when fromMap holds more '
        '(post cross-device merge)', () {
      final s = Uuid.generate();
      // Simulate a server-merged map with more than maxPerSource cells for
      // one source (the server unions, it does not re-cap).
      final raw = <String, dynamic>{
        s.toString(): {
          for (var i = 0; i < MoveAffinity.maxPerSource + 5; i++)
            Uuid.generate().toString(): 1000 + i,
        },
      };
      expect(MoveAffinity.fromMap(raw).destsFor(s).length,
          MoveAffinity.maxPerSource);
    });

    test('toMap ↔ fromMap round-trips', () {
      final s = Uuid.generate();
      final d = Uuid.generate();
      final a =
          MoveAffinity.fromMap(null).recordMove(s, d, DateTime.fromMillisecondsSinceEpoch(123));
      final round = MoveAffinity.fromMap(a.toMap());
      expect(round.destsFor(s).map((u) => u.toString()), [d.toString()]);
    });
  });

  group('sharedSourceFocusId', () {
    test('single shared source → that id', () {
      final s = Uuid.generate();
      expect(sharedSourceFocusId([s, s, s])?.toString(), s.toString());
    });
    test('multiple distinct sources → null', () {
      expect(sharedSourceFocusId([Uuid.generate(), Uuid.generate()]), isNull);
    });
    test('empty → null', () {
      expect(sharedSourceFocusId(const <Uuid>[]), isNull);
    });
  });

  group('movePairs', () {
    test('dedups distinct sources, each paired with the destination', () {
      final s1 = Uuid.generate();
      final s2 = Uuid.generate();
      final dest = Uuid.generate();
      final pairs = movePairs([s1, s1, s2, s1], dest);
      expect(pairs.length, 2);
      expect(pairs[0].$1.toString(), s1.toString());
      expect(pairs[0].$2.toString(), dest.toString());
      expect(pairs[1].$1.toString(), s2.toString());
      expect(pairs[1].$2.toString(), dest.toString());
    });

    test('empty sources → empty', () {
      expect(movePairs(const <Uuid>[], Uuid.generate()), isEmpty);
    });
  });
}

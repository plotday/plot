import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/thread_merge.dart';
import 'package:plot/store/store.dart';

Uuid _id(int n) => Uuid.fromString(
      '00000000-0000-0000-0000-${n.toString().padLeft(12, '0')}',
    );

void main() {
  group('mergeAudienceUnion', () {
    test('returns target when source is null', () {
      final target = [_id(1), _id(2)];
      expect(mergeAudienceUnion(target, null), target);
    });

    test('returns source when target is null', () {
      final source = [_id(1), _id(2)];
      expect(mergeAudienceUnion(null, source), source);
    });

    test('unions disjoint lists', () {
      final result = mergeAudienceUnion([_id(1)], [_id(2)]);
      expect(result, containsAll([_id(1), _id(2)]));
      expect(result!.length, 2);
    });

    test('dedupes overlapping ids', () {
      final result = mergeAudienceUnion([_id(1), _id(2)], [_id(2), _id(3)]);
      expect(result!.toSet(), {_id(1), _id(2), _id(3)});
      expect(result.length, 3);
    });

    test('preserves target order, appends new ids from source', () {
      final result =
          mergeAudienceUnion([_id(1), _id(2)], [_id(2), _id(3), _id(1)]);
      expect(result, [_id(1), _id(2), _id(3)]);
    });

    test('returns null when both inputs are null or empty', () {
      expect(mergeAudienceUnion(null, null), null);
      expect(mergeAudienceUnion([], []), null);
    });
  });

  group('splitAudienceSubtract', () {
    test('removes ids that only the split-out source contributed', () {
      final result = splitAudienceSubtract(
        target: [_id(1), _id(2), _id(3)],
        source: [_id(2), _id(3)],
        otherActiveSources: const [],
      );
      expect(result, [_id(1)]);
    });

    test('keeps ids that another still-merged source carries', () {
      final result = splitAudienceSubtract(
        target: [_id(1), _id(2), _id(3)],
        source: [_id(2), _id(3)],
        otherActiveSources: [
          [_id(3)],
        ],
      );
      expect(result, [_id(1), _id(3)]);
    });

    test('overlap with pre-merge target is dropped (lossy as documented)', () {
      // Pre-merge target had [1, 2]. Source had [2, 3]. Merged: [1, 2, 3].
      // Split: subtract source's contribution → [1]. The 2 that target also
      // had pre-merge is dropped. This is the accepted lossy case.
      final result = splitAudienceSubtract(
        target: [_id(1), _id(2), _id(3)],
        source: [_id(2), _id(3)],
        otherActiveSources: const [],
      );
      expect(result, [_id(1)]);
    });

    test('null source treated as empty contribution', () {
      final result = splitAudienceSubtract(
        target: [_id(1), _id(2)],
        source: null,
        otherActiveSources: const [],
      );
      expect(result, [_id(1), _id(2)]);
    });

    test('returns null when target becomes empty', () {
      final result = splitAudienceSubtract(
        target: [_id(1)],
        source: [_id(1)],
        otherActiveSources: const [],
      );
      expect(result, null);
    });
  });

  // mergeUrgencyMostUrgent was removed with the urgency field; the
  // merge path now ORs the new `urgent` bool directly (see
  // command/thread.dart MergeThread).

  group('mergeImportanceMax', () {
    test('returns max', () {
      expect(mergeImportanceMax(0, 5), 5);
      expect(mergeImportanceMax(5, 0), 5);
      expect(mergeImportanceMax(3, 3), 3);
    });
  });

}

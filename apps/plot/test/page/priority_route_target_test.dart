import 'package:flutter_test/flutter_test.dart';
import 'package:plot/page/priority.dart';
import 'package:plot/store/store.dart' show Uuid;

void main() {
  group('parsePriorityRouteTarget', () {
    test('the reserved segment maps to Everything mode', () {
      final t = parsePriorityRouteTarget(kEverythingRouteSegment);
      expect(t.everything, isTrue);
      expect(t.priorityId, isNull);
      expect(t.invalid, isFalse);
    });

    test('a valid base58 id maps to a scoped focus', () {
      final id = Uuid.generate();
      final t = parsePriorityRouteTarget(id.toShortString());
      expect(t.everything, isFalse);
      expect(t.priorityId, id);
      expect(t.invalid, isFalse);
    });

    test('an unparseable segment is invalid', () {
      final t = parsePriorityRouteTarget('!!!not-base58!!!');
      expect(t.everything, isFalse);
      expect(t.priorityId, isNull);
      expect(t.invalid, isTrue);
    });

    test('identical parsed targets are equal (value equality)', () {
      expect(
        parsePriorityRouteTarget(kEverythingRouteSegment),
        equals(parsePriorityRouteTarget(kEverythingRouteSegment)),
      );
    });
  });

  group('PriorityOnlyPage sentinel awareness (single-panel feed)', () {
    // Regression: the single-panel feed page must treat `/p/everything` as
    // Everything (null id, not invalid) rather than decoding the reserved word
    // as a base58 priority id. A bare `PriorityId.tryFromShortString`
    // ('everything') returns a garbage non-null id (all-valid base58), which
    // would mount a scoped focus and reintroduce the Everything→Inbox bug on
    // single-panel cold loads/refreshes.
    test('the reserved segment resolves to Everything, not a garbage id', () {
      final page = PriorityOnlyPage(priorityIdString: kEverythingRouteSegment);
      expect(page.target.everything, isTrue);
      expect(page.target.priorityId, isNull);
      expect(page.target.invalid, isFalse);
    });

    test('a valid base58 id still resolves to a scoped focus', () {
      final id = Uuid.generate();
      final page = PriorityOnlyPage(priorityIdString: id.toShortString());
      expect(page.target.everything, isFalse);
      expect(page.target.priorityId, id);
      expect(page.target.invalid, isFalse);
    });
  });
}

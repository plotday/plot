import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// Regression tests for the share-picker contact ranking.
///
/// Bug: the "authored" band (people the user has written to) was built by
/// intersecting the *recent* thread window with the user's authored threads.
/// In an aggregating parent/root priority the recent window is a tiny,
/// recency-biased slice of thousands of threads, so the user's authored
/// relationships fall outside it and the band is starved — leaving
/// high-frequency mailing lists to dominate the picker.
///
/// The fix sources the authored band from the user's authored threads
/// directly (a separate ordered list), independent of the recent window.
void main() {
  group('Actor.buildShareScan', () {
    test(
        'authored band is sourced from authored threads, not the recent window',
        () {
      final me = Uuid.generate();
      final beth = Uuid.generate(); // user has authored to Beth (older threads)
      final mailingList =
          Uuid.generate(); // only on recent inbound (non-authored) threads

      // Recent window: dominated by an inbound mailing-list thread the user
      // never wrote in. Beth does not appear here at all.
      final recent = [
        for (var i = 0; i < 10; i++)
          ShareScanThread(
            id: Uuid.generate(),
            contacts: [me, mailingList],
            groups: const [],
            isExplicit: true,
          ),
      ];
      // Authored threads (older, outside the recent window): the user wrote
      // notes on threads that include Beth.
      final authored = [
        ShareScanThread(
          id: Uuid.generate(),
          contacts: [me, beth],
          groups: const [],
        ),
        ShareScanThread(
          id: Uuid.generate(),
          contacts: [me, beth],
          groups: const [],
        ),
      ];

      final scan = Actor.buildShareScan(
        recent: recent,
        authored: authored,
        selfIds: {me},
      );

      // Beth lands in the authored band even though she is absent from the
      // recent window — this is the behavior the parent-priority bug broke.
      expect(scan.authoredFirstSeenIndex.containsKey(beth), isTrue);
      expect(scan.authoredCounts[beth], 2);

      // The mailing list is only ever a received-only (explicit, non-authored)
      // contact, so it must never enter the authored band.
      expect(scan.authoredFirstSeenIndex.containsKey(mailingList), isFalse);
      expect(scan.explicitFirstSeenIndex.containsKey(mailingList), isTrue);

      // The user's own ids are excluded from every tally.
      expect(scan.authoredFirstSeenIndex.containsKey(me), isFalse);
      expect(scan.firstSeenIndex.containsKey(me), isFalse);
    });

    test('authoredFirstSeenIndex orders by authored-thread recency', () {
      final me = Uuid.generate();
      final recent = Uuid.generate(); // first in the authored list = most recent
      final older = Uuid.generate();

      final authored = [
        ShareScanThread(id: Uuid.generate(), contacts: [me, recent], groups: const []),
        ShareScanThread(id: Uuid.generate(), contacts: [me, older], groups: const []),
      ];

      final scan = Actor.buildShareScan(
        recent: const [],
        authored: authored,
        selfIds: {me},
      );

      expect(scan.authoredFirstSeenIndex[recent], 0);
      expect(scan.authoredFirstSeenIndex[older], 1);
    });
  });
}

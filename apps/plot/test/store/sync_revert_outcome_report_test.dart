import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// A "permanent" sync-push rejection (a 4xx the client can't retry its way out
/// of) is followed by an attempt to revert the local row to the server's
/// version. The outcome of that revert decides whether we report the rejection
/// to error tracking.
///
/// `absentOnServer` is the EXPECTED transient case: the row is an unsynced
/// create the server hasn't seen yet — almost always because a parent row (a
/// note's thread, which files `thread_priority`) hasn't been pushed in this
/// cycle. The row is kept `pending` and the next sync retries, so it
/// self-heals. Capturing it as "Permanent sync push rejected" floods error
/// tracking with noise for a no-data-loss, self-correcting condition (PostHog
/// issue 019f0508). Only `reverted` (we discarded the user's local edit) and
/// `fetchFailed` (we couldn't determine remote state) are worth surfacing.
void main() {
  group('shouldReportRevertOutcome', () {
    test('absentOnServer is the transient retry case — not reported', () {
      expect(Store.shouldReportRevertOutcome('absentOnServer'), isFalse);
    });

    test('reverted (local edit discarded) is reported', () {
      expect(Store.shouldReportRevertOutcome('reverted'), isTrue);
    });

    test('fetchFailed (unknown remote state) is reported', () {
      expect(Store.shouldReportRevertOutcome('fetchFailed'), isTrue);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/thread.dart';

/// Regression test for empty participant-header bands on thread rows.
///
/// A thread whose only contact is an id that never resolves to an actor (e.g.
/// the Plot Updates topic threads, whose `contacts` reference a global "Plot"
/// twist instance that isn't synced to a given client) used to reserve the
/// header name slot forever — the slot is gated on the *stable* id set so it
/// doesn't shift while names warm in, but the name never arrived, leaving a
/// permanent empty band above the title. The slot must collapse once actor
/// loading has finished with nothing to show.
void main() {
  group('reserveContactsLabel', () {
    test('reserves while actors are still loading (avoids layout shift)', () {
      expect(
        reserveContactsLabel(
          isChannelThread: false,
          hasContactIds: true,
          actorsLoaded: false,
          hasResolvedLabel: false,
        ),
        isTrue,
      );
    });

    test('keeps the slot once a name has resolved', () {
      expect(
        reserveContactsLabel(
          isChannelThread: false,
          hasContactIds: true,
          actorsLoaded: true,
          hasResolvedLabel: true,
        ),
        isTrue,
      );
    });

    test(
      'collapses when loading finished with no resolvable name '
      '(the empty-band bug)',
      () {
        expect(
          reserveContactsLabel(
            isChannelThread: false,
            hasContactIds: true,
            actorsLoaded: true,
            hasResolvedLabel: false,
          ),
          isFalse,
        );
      },
    );

    test('never reserves when there are no contact ids', () {
      expect(
        reserveContactsLabel(
          isChannelThread: false,
          hasContactIds: false,
          actorsLoaded: false,
          hasResolvedLabel: false,
        ),
        isFalse,
      );
    });

    test('never reserves for channel threads (they use the breadcrumb)', () {
      expect(
        reserveContactsLabel(
          isChannelThread: true,
          hasContactIds: true,
          actorsLoaded: true,
          hasResolvedLabel: true,
        ),
        isFalse,
      );
    });
  });
}

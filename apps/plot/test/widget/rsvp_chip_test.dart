import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/avatar.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/thread.dart';

void main() {
  group('RsvpChip.toneFor', () {
    test('attend → going', () {
      expect(RsvpChip.toneFor('attend'), RsvpTone.going);
    });
    test('skip → declined', () {
      expect(RsvpChip.toneFor('skip'), RsvpTone.declined);
    });
    test('null → neutral', () {
      expect(RsvpChip.toneFor(null), RsvpTone.neutral);
    });
    test('unknown/tentative → neutral', () {
      expect(RsvpChip.toneFor('tentative'), RsvpTone.neutral);
    });
  });

  group('RsvpChip.segmentsFor', () {
    test('includes only non-zero segments, in going/declined/undecided order', () {
      final segs = RsvpChip.segmentsFor((attend: 5, skip: 0, undecided: 1));
      expect(segs, [
        (icon: PlotIcon.rsvpGoing, count: 5),
        (icon: PlotIcon.rsvpUndecided, count: 1),
      ]);
    });
    test('all three present', () {
      final segs = RsvpChip.segmentsFor((attend: 3, skip: 2, undecided: 4));
      expect(segs, [
        (icon: PlotIcon.rsvpGoing, count: 3),
        (icon: PlotIcon.rsvpDeclined, count: 2),
        (icon: PlotIcon.rsvpUndecided, count: 4),
      ]);
    });
    test('all zero → empty', () {
      expect(RsvpChip.segmentsFor((attend: 0, skip: 0, undecided: 0)), isEmpty);
    });
  });

  group('RsvpDetails.group', () {
    ScheduleContact c(String? status) =>
        ScheduleContact(contactId: 'x', status: status);

    test('partitions by status into going/declined/undecided', () {
      final g = RsvpDetails.group([c('attend'), c('skip'), c(null), c('attend')]);
      expect(g.going.length, 2);
      expect(g.declined.length, 1);
      expect(g.undecided.length, 1);
    });

    test('non-attend/skip statuses fall into undecided', () {
      final g = RsvpDetails.group([c('tentative'), c(null)]);
      expect(g.going, isEmpty);
      expect(g.declined, isEmpty);
      expect(g.undecided.length, 2);
    });

    ScheduleContact cu(String id, String? status, {String? userId}) =>
        ScheduleContact(contactId: id, status: status, contactUserId: userId);

    test('floats the current user to the front of their group', () {
      final g = RsvpDetails.group(
        [
          cu('a', 'skip'),
          cu('me', 'skip', userId: 'u1'),
          cu('b', 'skip'),
        ],
        userId: 'u1',
      );
      expect(g.declined.map((c) => c.contactId), ['me', 'a', 'b']);
    });

    test('floats all of the user\'s contacts first, stably', () {
      final g = RsvpDetails.group(
        [
          cu('a', 'attend'),
          cu('work', 'attend', userId: 'u1'),
          cu('b', 'attend'),
          cu('home', 'attend', userId: 'u1'),
        ],
        userId: 'u1',
      );
      expect(g.going.map((c) => c.contactId), ['work', 'home', 'a', 'b']);
    });

    test('leaves order unchanged when no userId is given', () {
      final g = RsvpDetails.group([
        cu('a', 'skip'),
        cu('me', 'skip', userId: 'u1'),
        cu('b', 'skip'),
      ]);
      expect(g.declined.map((c) => c.contactId), ['a', 'me', 'b']);
    });
  });
}

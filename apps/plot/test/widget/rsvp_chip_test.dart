import 'package:flutter_test/flutter_test.dart';
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
}

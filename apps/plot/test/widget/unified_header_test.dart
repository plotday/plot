import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/unified_header.dart';

/// The single-panel header's leading back chevron should have no inert tap
/// padding around it. The horizontal placement is decided by
/// [headerLeadingPadding], which splits the leading inset between the header's
/// content padding (outside the chevron, inert) and the chevron's own
/// `startInset` (inside it, tappable).
///
/// The key invariant: the two always sum to the same value, so folding padding
/// into the chevron never shifts the glyph — it only converts dead space into
/// hit area.
void main() {
  group('headerLeadingPadding', () {
    test('absorbs the leading padding into the chevron when present', () {
      // A back chevron: the leading content padding moves inside the chevron so
      // the leading edge becomes tappable. Holds on every platform — desktop's
      // traffic lights are reserved by a separate toolbar gutter, so the
      // chevron still sits clear of them.
      final pad = headerLeadingPadding(hasBack: true);
      expect(pad.contentPadLeft, 0);
      expect(pad.backStartInset, greaterThan(0));
    });

    test('leaves the leading padding outside when there is no chevron', () {
      final pad = headerLeadingPadding(hasBack: false);
      expect(pad.contentPadLeft, greaterThan(0));
      expect(pad.backStartInset, 0);
    });

    test('the split always sums to the same leading inset (glyph never moves)', () {
      final withBack = headerLeadingPadding(hasBack: true);
      final noBack = headerLeadingPadding(hasBack: false);

      double total(({double contentPadLeft, double backStartInset}) p) =>
          p.contentPadLeft + p.backStartInset;

      expect(total(withBack), total(noBack));
    });
  });
}

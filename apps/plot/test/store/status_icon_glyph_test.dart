import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  test('every StatusIcon maps to a distinct, non-null glyph', () {
    final glyphs = StatusIcon.values.map((s) => s.glyph).toList();
    expect(glyphs, hasLength(StatusIcon.values.length));
    expect(glyphs.whereType<Null>(), isEmpty);
    expect(glyphs.toSet(), hasLength(StatusIcon.values.length));
  });
}

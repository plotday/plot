import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/emoji.dart';

void main() {
  group('EmojiCommandIcon.glyphNudgeFraction', () {
    test('native keeps the calibrated 0.125 down-nudge', () {
      expect(
        EmojiCommandIcon.glyphNudgeFraction(isWeb: false, isCustomEmoji: false),
        0.125,
      );
    });

    test('web under-shifts vs native so the bitmap glyph is not pushed low', () {
      final web = EmojiCommandIcon.glyphNudgeFraction(
        isWeb: true,
        isCustomEmoji: false,
      );
      final native = EmojiCommandIcon.glyphNudgeFraction(
        isWeb: false,
        isCustomEmoji: false,
      );
      // The bug: CanvasKit places the CBDT/CBLC bitmap glyph lower in its line
      // box, so reusing the native nudge sat the emoji visibly low. Web must
      // use a smaller nudge.
      expect(web, lessThan(native));
      expect(web, closeTo(0.05, 1e-9));
    });

    test('custom-emoji images are already centered — no nudge on any platform',
        () {
      expect(
        EmojiCommandIcon.glyphNudgeFraction(isWeb: true, isCustomEmoji: true),
        0.0,
      );
      expect(
        EmojiCommandIcon.glyphNudgeFraction(isWeb: false, isCustomEmoji: true),
        0.0,
      );
    });
  });
}

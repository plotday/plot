import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  group('Thread.createPreviewFromMarkdown', () {
    test('strips email preheader padding (zero-width invisibles)', () {
      // Real-world newsletter preheader: a space + combining grapheme joiner
      // (U+034F) + zero-width space (U+200B) repeated to push later content
      // out of the inbox snippet. The invisibles are not matched by \s, so
      // without stripping them the collapse leaves the spaces between them
      // intact and the preview renders as text followed by blank space.
      final padding = ' \u034F\u200B' * 20;
      final input =
          'Breathe some fresh air into your releases.${padding}Read the changelog';

      final preview = Thread.createPreviewFromMarkdown(input);

      expect(
        preview,
        'Breathe some fresh air into your releases. Read the changelog',
      );
      // No consecutive spaces, no surviving invisible characters.
      expect(RegExp(r' {2,}').hasMatch(preview!), isFalse);
      expect(RegExp(r'[\u00AD\u034F\u061C\u200B-\u200F\u2060-\u2064\u206A-\u206F\uFEFF]').hasMatch(preview), isFalse);
    });

    test('removes a variety of zero-width / invisible format characters', () {
      final input = 'Hello\u200B\u200C\u200D\u2060\uFEFF\u00AD\u034F world';
      expect(Thread.createPreviewFromMarkdown(input), 'Hello world');
    });
  });
}

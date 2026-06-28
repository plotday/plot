import 'package:flutter_test/flutter_test.dart';

import 'package:plot/share_intent.dart';

void main() {
  group('extractHttpUrl', () {
    test('returns a bare URL unchanged', () {
      expect(
        extractHttpUrl('https://example.com/article'),
        'https://example.com/article',
      );
    });

    test('trims surrounding whitespace from a bare URL', () {
      expect(
        extractHttpUrl('  https://example.com/article  \n'),
        'https://example.com/article',
      );
    });

    test('extracts the URL from a "Title\\nURL" payload', () {
      expect(
        extractHttpUrl('Great article\nhttps://example.com/article'),
        'https://example.com/article',
      );
    });

    // The common Android case that regressed: many share sources (YouTube,
    // news apps, social, and plain text-selection shares) put descriptive
    // text and the URL on the SAME line. The old line-by-line scan only
    // matched a URL that was alone on its line, so these returned null and
    // the share was silently dropped — the app just opened to the home tab.
    test('extracts a URL that trails descriptive text on one line', () {
      expect(
        extractHttpUrl('Check out this great article https://example.com/article'),
        'https://example.com/article',
      );
    });

    test('extracts a URL that leads trailing text on one line', () {
      expect(
        extractHttpUrl('https://youtu.be/dQw4w9WgXcQ shared via YouTube'),
        'https://youtu.be/dQw4w9WgXcQ',
      );
    });

    test('extracts a URL embedded mid-sentence', () {
      expect(
        extractHttpUrl('I thought https://example.com/x was interesting'),
        'https://example.com/x',
      );
    });

    test('extracts an http (non-TLS) URL on a shared line', () {
      expect(
        extractHttpUrl('legacy link http://example.com/page here'),
        'http://example.com/page',
      );
    });

    test('strips trailing sentence punctuation from an embedded URL', () {
      expect(
        extractHttpUrl('Read this: https://example.com/article.'),
        'https://example.com/article',
      );
    });

    test('returns null when there is no URL', () {
      expect(extractHttpUrl('just some shared text, no link'), isNull);
    });

    test('returns null for null/empty/whitespace input', () {
      expect(extractHttpUrl(null), isNull);
      expect(extractHttpUrl(''), isNull);
      expect(extractHttpUrl('   \n  '), isNull);
    });

    test('ignores non-http schemes', () {
      expect(extractHttpUrl('mailto:someone@example.com'), isNull);
      expect(extractHttpUrl('ftp://example.com/file'), isNull);
    });
  });
}

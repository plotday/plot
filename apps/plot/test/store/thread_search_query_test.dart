import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  group('Thread.sanitizeSearchWords', () {
    test('preserves dot-containing words for the LIKE branch', () {
      // The dot is intentionally NOT stripped — the LIKE branch on
      // links.source_url uses the un-split word so 'cal.com' matches
      // URLs containing 'cal.com' as a substring.
      expect(Thread.sanitizeSearchWords('cal.com'), ['cal.com']);
    });

    test('drops words shorter than 2 chars', () {
      expect(Thread.sanitizeSearchWords('a hi b'), ['hi']);
    });

    test('strips FTS5 special chars but keeps the surviving stem', () {
      expect(Thread.sanitizeSearchWords('foo* bar+'), ['foo', 'bar']);
    });
  });

  group('Thread.ftsQueryFromWords', () {
    test("'cal.com' tokenises to 'cal* com*' instead of producing FTS5 syntax error", () {
      // Regression: the prior implementation built `MATCH 'cal.com*'`,
      // which SQLite FTS5 rejects with `fts5: syntax error near "."`,
      // aborting the entire search query.
      expect(
        Thread.ftsQueryFromWords(Thread.sanitizeSearchWords('cal.com')),
        'cal* com*',
      );
    });

    test('plain word becomes a single prefix term', () {
      expect(
        Thread.ftsQueryFromWords(Thread.sanitizeSearchWords('hello')),
        'hello*',
      );
    });

    test('multiple words are space-joined (implicit AND)', () {
      expect(
        Thread.ftsQueryFromWords(Thread.sanitizeSearchWords('alice email')),
        'alice* email*',
      );
    });

    test('drops sub-tokens shorter than 2 chars', () {
      // 'a.bc' splits into ['a', 'bc']; the 1-char 'a' is dropped so the
      // FTS query is just 'bc*'.
      expect(
        Thread.ftsQueryFromWords(Thread.sanitizeSearchWords('a.bc')),
        'bc*',
      );
    });

    test('returns empty when no token survives splitting', () {
      // 'a.b' → ['a', 'b'], both <2 chars after split → empty FTS query.
      // The caller skips the FTS branch in that case and falls back to
      // the link-LIKE branch.
      expect(
        Thread.ftsQueryFromWords(Thread.sanitizeSearchWords('a.b')),
        '',
      );
    });
  });
}

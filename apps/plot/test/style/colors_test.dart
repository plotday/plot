import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/style/colors.dart';

void main() {
  group('header background bands', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      test('sectionHeaderBackground sits between background and page band '
          '($brightness)', () {
        final scheme = ColourSchemeData(
          themeColor: const ThemeColor.defaultColor(),
          brightness: brightness,
        );
        final bg = scheme.background.computeLuminance();
        final section = scheme.sectionHeaderBackground.computeLuminance();
        final page = scheme.pageHeaderBackground.computeLuminance();
        // Darker than the surface it sits on...
        expect(section, lessThan(bg));
        // ...but gentler (lighter) than the heavier page-header bar.
        expect(section, greaterThan(page));
      });
    }
  });

  group('link colour', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      test('a non-gray priority links with its own accent, never the focus '
          'theme ($brightness)', () {
        // Regression: in the Everything feed the surrounding focus theme is
        // gray (7) while the opened thread keeps its own priority colour. The
        // link styler used to read the fallback colour off context.theme
        // (the focus), so a teal-priority thread's links rendered as the
        // invisible gray theme-7 accent. linkColor must derive solely from the
        // thread's own scheme.
        final teal = ColourSchemeData(
          themeColor: const ThemeColor(0),
          brightness: brightness,
        );
        final gray = ColourSchemeData(
          themeColor: const ThemeColor(7),
          brightness: brightness,
        );
        // Teal priority: links use teal's own accent...
        expect(teal.linkColor, equals(teal.accent));
        // ...and are NOT the near-invisible gray theme-7 accent.
        expect(teal.linkColor, isNot(equals(gray.accent)));
      });

      test('a gray (theme 7) priority falls back to theme 0 teal '
          '($brightness)', () {
        final gray = ColourSchemeData(
          themeColor: const ThemeColor(7),
          brightness: brightness,
        );
        // Theme 7's own accent is near-zero chroma (invisible), so links fall
        // back to the brand teal (theme 0) rather than the gray accent.
        expect(
          gray.linkColor,
          equals(gray.colours.fromTheme(const ThemeColor(0))),
        );
        expect(gray.linkColor, isNot(equals(gray.accent)));
      });
    }
  });
}

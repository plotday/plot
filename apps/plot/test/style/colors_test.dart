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
}

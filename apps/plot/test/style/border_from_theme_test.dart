import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/util/theme_color.dart';

void main() {
  group('OklchColours.borderFromTheme', () {
    OklchColours coloursFor(Brightness brightness) => ColourSchemeData(
      themeColor: const ThemeColor.defaultColor(),
      brightness: brightness,
    ).colours;

    test('ring differs from the tint background (more visible) in light mode', () {
      final colours = coloursFor(Brightness.light);
      const purple = ThemeColor(2);
      // The ring is the tinted background pushed to a more visible lightness,
      // so it must NOT equal the fill it sits on — otherwise it is invisible.
      expect(
        colours.borderFromTheme(purple),
        isNot(equals(colours.backgroundFromTheme(purple))),
      );
    });

    test('ring differs from the tint background in dark mode', () {
      final colours = coloursFor(Brightness.dark);
      const purple = ThemeColor(2);
      expect(
        colours.borderFromTheme(purple),
        isNot(equals(colours.backgroundFromTheme(purple))),
      );
    });

    test('ring is fully opaque', () {
      final colours = coloursFor(Brightness.light);
      expect(colours.borderFromTheme(const ThemeColor(2)).opacity, 1.0);
    });

    test('ring hue tracks the focus color (different colors → different rings)', () {
      final colours = coloursFor(Brightness.light);
      expect(
        colours.borderFromTheme(const ThemeColor(2)), // purple
        isNot(equals(colours.borderFromTheme(const ThemeColor(4)))), // red
      );
    });

    test('null color falls back to the default focus color', () {
      final colours = coloursFor(Brightness.light);
      expect(
        colours.borderFromTheme(null),
        equals(colours.borderFromTheme(const ThemeColor.defaultColor())),
      );
    });
  });
}

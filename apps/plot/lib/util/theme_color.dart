import 'package:drift/drift.dart';

extension type ThemeColor(int index) {
  const ThemeColor.defaultColor() : index = 7;

  static final List<ThemeColor> options = [
    ThemeColor(0),
    ThemeColor(1),
    ThemeColor(2),
    ThemeColor(3),
    ThemeColor(4),
    ThemeColor(5),
    ThemeColor(6),
    ThemeColor(7),
  ];

  String get label => switch (index) {
    0 => 'Catalyst',
    1 => 'Call to Adventure',
    2 => 'Rising Action',
    3 => 'Momentum',
    4 => 'Turning Point',
    5 => 'Breakthrough',
    6 => 'Climax',
    7 => 'Resolution',
    _ => 'Unknown',
  };

  /// Returns the hue value (0-360) for this theme color
  double toHue() {
    return switch (index) {
      0 => 163.0, // Catalyst - teal green (brand)
      1 => 245.0, // Call to Adventure - indigo
      2 => 295.0, // Rising Action - purple (clear of pink zone)
      3 => 205.0, // Momentum - sky blue
      4 => 20.0, // Turning Point - red (max chroma for true red)
      5 => 64.0, // Breakthrough - orange
      6 => 105.0, // Climax - yellow
      7 => 163.0, // Resolution - brand (desaturated)
      _ => 0.0,
    };
  }

  /// Returns per-color chroma tuned to each hue's sRGB gamut ceiling.
  /// [isDark] selects dark-mode values (higher lightness = lower safe chroma).
  double toChroma({bool isDark = false}) {
    return switch (index) {
      0 => isDark ? 0.090 : 0.125, // teal - high gamut
      1 => isDark ? 0.110 : 0.120, // indigo - tighter gamut
      2 => isDark ? 0.120 : 0.145, // purple
      3 => isDark ? 0.120 : 0.180, // sky blue - moderate gamut
      4 => isDark ? 0.130 : 0.140, // red - push hard for true red
      5 => isDark ? 0.120 : 0.145, // orange
      6 => isDark ? 0.110 : 0.200, // yellow - push chroma hard in light
      7 => isDark ? 0.010 : 0.015, // gray (desaturated brand)
      _ => isDark ? 0.100 : 0.140,
    };
  }
}

class ThemeColorConverter extends TypeConverter<ThemeColor, int>
    with JsonTypeConverter2<ThemeColor, int, int> {
  const ThemeColorConverter();

  @override
  ThemeColor fromSql(int fromDb) => ThemeColor(fromDb);

  @override
  int toSql(ThemeColor value) => value.index;

  @override
  ThemeColor fromJson(int json) => fromSql(json);

  @override
  int toJson(ThemeColor value) => toSql(value);
}

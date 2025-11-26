import 'package:drift/drift.dart';

extension type ThemeColor(int index) {
  const ThemeColor.defaultColor() : index = 0;

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
      0 => 164.18, // Catalyst - green
      1 => 225.0, // Call to Adventure - blue
      2 => 275.0, // Rising Action - blue, too
      3 => 310.0, // Momentum - puple
      4 => 20.0, // Turning Point - pink
      5 => 54.0, // Breakthrough - orange
      6 => 108.0, // Climax - olive
      7 => 0.0, // Resolution - gray
      _ => 0.0, // Unknown - default to red
    };
  }

  double get chromaFactor => index == 7 ? 0.0 : 1.0;
}

class ThemeColorConverter extends TypeConverter<ThemeColor, int> {
  const ThemeColorConverter();

  @override
  ThemeColor fromSql(int fromDb) {
    return ThemeColor(fromDb);
  }

  @override
  int toSql(ThemeColor value) {
    return value.index;
  }
}

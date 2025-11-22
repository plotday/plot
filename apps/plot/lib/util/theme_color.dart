import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';

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
      1 => 0, // Call to Adventure - red
      2 => 210.0, // Rising Action - blue
      3 => 35.0, // Momentum - orange
      4 => 290.0, // Turning Point - purple
      5 => 174.0, // Breakthrough - teal
      6 => 15.0, // Climax - coral
      7 => 260.0, // Resolution - violet
      _ => 0.0, // Unknown - default to red
    };
  }

  /// Returns a Color generated from this theme color's hue
  Color toColor() {
    if (index < 0 || index > 7) {
      return const Color(0xFF9E9E9E); // Unknown - gray
    }
    return HSLColor.fromAHSL(1.0, toHue(), 0.6, 0.65).toColor();
  }
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

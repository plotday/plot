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

  Color toColor() {
    return switch (index) {
      0 => const Color(0xFFE57373), // Catalyst - red
      1 => const Color(0xFF81C784), // Call to Adventure - green
      2 => const Color(0xFF64B5F6), // Rising Action - blue
      3 => const Color(0xFFFFB74D), // Momentum - orange
      4 => const Color(0xFFBA68C8), // Turning Point - purple
      5 => const Color(0xFF4DB6AC), // Breakthrough - teal
      6 => const Color(0xFFFF8A65), // Climax - coral
      7 => const Color(0xFF9575CD), // Resolution - violet
      _ => const Color(0xFF9E9E9E), // Unknown - gray
    };
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

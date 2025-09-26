
import 'package:drift/drift.dart';

extension type ThemeColor(int index) {
  const ThemeColor.defaultColor() : index = 0;
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

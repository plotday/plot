import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/json_map_converter.dart';

void main() {
  const c = JsonMapConverter();

  test('toSql / fromSql round-trip', () {
    final map = {
      's1': {'d1': 100, 'd2': 200},
    };
    final sql = c.toSql(map);
    expect(c.fromSql(sql), map);
  });

  test('fromSql tolerates empty string → empty map', () {
    expect(c.fromSql(''), <String, dynamic>{});
  });

  test('toJson / fromJson pass the object through (sync wire)', () {
    final map = {
      's1': {'d1': 100},
    };
    expect(c.toJson(map), map);
    expect(c.fromJson(map), map);
  });
}

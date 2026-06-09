import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  group('toEncodableSyncValue', () {
    test('a raw BigInt is not JSON-encodable (reproduces the sync failure)', () {
      // Drift's default serializer emits Int64Column values (e.g.
      // thread.team_id) as a raw BigInt. This is the exact shape that broke
      // sync: jsonEncode throws, the push aborts, and the row is stranded.
      final body = <String, dynamic>{
        'id': 'abc',
        'team_id': BigInt.parse('7000000000000000123'),
      };
      expect(() => jsonEncode(body), throwsA(isA<JsonUnsupportedObjectError>()));
    });

    test('stringifies a top-level BigInt losslessly', () {
      final big = BigInt.parse('7000000000000000123');
      final result =
          toEncodableSyncValue(<String, dynamic>{'team_id': big})
              as Map<String, dynamic>;

      expect(result['team_id'], '7000000000000000123');
      // The whole body now round-trips through jsonEncode without throwing.
      expect(jsonEncode(result), '{"team_id":"7000000000000000123"}');
    });

    test('passes through values that are already encodable', () {
      final body = <String, dynamic>{
        'id': 'abc',
        'title': 'hello',
        'count': 3,
        'ratio': 1.5,
        'flag': true,
        'nothing': null,
      };
      final result = toEncodableSyncValue(body) as Map<String, dynamic>;

      expect(result, body);
      expect(jsonEncode(result), jsonEncode(body));
    });

    test('descends into nested maps and lists', () {
      final body = <String, dynamic>{
        'contact_meta': {
          'c1': {'role': 'owner', 'team': BigInt.from(42)},
        },
        'ids': [BigInt.from(1), BigInt.from(2), 'x'],
      };
      final result = toEncodableSyncValue(body) as Map<String, dynamic>;

      expect((result['contact_meta'] as Map)['c1']['team'], '42');
      expect(result['ids'], ['1', '2', 'x']);
      // Encodes cleanly now.
      expect(jsonEncode(result), isNotEmpty);
    });
  });
}

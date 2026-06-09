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

    test('handles Iterables that are not Lists (like Set)', () {
      final body = <String, dynamic>{
        'tags': {'a', 'b', 'c'},
      };
      final result = toEncodableSyncValue(body) as Map<String, dynamic>;

      expect(result['tags'], ['a', 'b', 'c']);
      expect(jsonEncode(result), '{"tags":["a","b","c"]}');
    });

    test('handles DateTime explicitly', () {
      final dt = DateTime.utc(2026, 6, 9, 12, 34, 56);
      final body = <String, dynamic>{
        'created_at': dt,
      };
      final result = toEncodableSyncValue(body) as Map<String, dynamic>;

      expect(result['created_at'], '2026-06-09T12:34:56.000Z');
      expect(jsonEncode(result), '{"created_at":"2026-06-09T12:34:56.000Z"}');
    });

    test('calls toJson() on custom objects', () {
      final body = <String, dynamic>{
        'custom': _CustomEncodable(),
      };
      final result = toEncodableSyncValue(body) as Map<String, dynamic>;

      expect(result['custom'], {'id': '123'});
      expect(jsonEncode(result), '{"custom":{"id":"123"}}');
    });

    test('falls back to toString() for unhandled types', () {
      final body = <String, dynamic>{
        'weird': _WeirdObject(),
      };
      final result = toEncodableSyncValue(body) as Map<String, dynamic>;

      expect(result['weird'], 'Weird(42)');
      expect(jsonEncode(result), '{"weird":"Weird(42)"}');
    });
  });
}

class _CustomEncodable {
  Map<String, dynamic> toJson() => {'id': '123'};
}

class _WeirdObject {
  @override
  String toString() => 'Weird(42)';
}

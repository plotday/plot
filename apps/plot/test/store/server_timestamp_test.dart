import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// Guards the single source of truth for serializing DateTimes sent to the
/// server. Store rows come back LOCAL (LocalDateTimeConverter.fromSql calls
/// `.toLocal()`), so a bare `toIso8601String()` emits a timezone-naive string
/// the server misreads as UTC. `toServerTimestamp` must always emit UTC (with a
/// trailing `Z`), and every server-bound serialization must route through it.
void main() {
  test('toServerTimestamp converts a local DateTime to UTC (trailing Z)', () {
    final local = DateTime(2026, 1, 2, 9); // isUtc == false
    expect(local.isUtc, isFalse, reason: 'guard: input must be local');

    final serialized = toServerTimestamp(local);

    expect(serialized, endsWith('Z'),
        reason: 'server-bound timestamps must be UTC-marked');
    expect(serialized, local.toUtc().toIso8601String(),
        reason: 'the serialized instant must equal the UTC of the input');
  });

  test('toServerTimestamp is a no-op shape for an already-UTC DateTime', () {
    final utc = DateTime.utc(2026, 1, 2, 9);
    expect(toServerTimestamp(utc), utc.toIso8601String());
    expect(toServerTimestamp(utc), endsWith('Z'));
  });

  test('buildRangeParams serializes range bounds as UTC (query params)', () {
    // Query params never pass through the JSON body walker
    // (`toEncodableSyncValue`), so they must call `toServerTimestamp`
    // themselves. A local range would otherwise shift the server window by the
    // device's UTC offset.
    final range = DateTimeRange(DateTime(2026, 1, 2, 9), DateTime(2026, 1, 3, 9));
    final params = ThreadsBase().buildRangeParams(range);

    expect(params['range_start'], endsWith('Z'));
    expect(params['range_end'], endsWith('Z'));
    expect(params['range_start'],
        DateTime(2026, 1, 2, 9).toUtc().toIso8601String());
  });
}

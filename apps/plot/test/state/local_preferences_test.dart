import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/local_preferences.dart';
import 'package:plot/util/profile_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ProfilePreferences.init();
  });

  group('LocalPreferencesBloc connection MRU', () {
    test('records per-priority usage and ranks priority-recency first',
        () async {
      final bloc = LocalPreferencesBloc();
      // Ensure async constructor load has settled.
      await Future<void>.delayed(Duration.zero);

      // Use B once globally, A once in priority p1.
      await bloc.recordConnectionUsage(channelKey: 'B', priorityId: 'pX');
      await bloc.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');

      // Rank for p1: A (priority match) before B (global only).
      final ranked = bloc.rankConnectionsByMru(
        keys: ['B', 'A', 'C'],
        priorityId: 'p1',
      );
      expect(ranked, ['A', 'B', 'C']);
    });

    test('within priority, most recent priority use wins', () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      await bloc.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await bloc.recordConnectionUsage(channelKey: 'B', priorityId: 'p1');

      final ranked = bloc.rankConnectionsByMru(
        keys: ['A', 'B'],
        priorityId: 'p1',
      );
      expect(ranked, ['B', 'A']);
    });

    test('persists across instances', () async {
      final bloc1 = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      await bloc1.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');

      final bloc2 = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      final ranked = bloc2.rankConnectionsByMru(
        keys: ['B', 'A'],
        priorityId: 'p1',
      );
      expect(ranked, ['A', 'B']);
    });

    test('unseen keys preserve their input order', () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      final ranked = bloc.rankConnectionsByMru(
        keys: ['Z', 'A', 'M'],
        priorityId: 'p1',
      );
      expect(ranked, ['Z', 'A', 'M']);
    });
  });

  group('lastUsedConnectionKey', () {
    test('prefers a use in the current priority over a more-recent global use',
        () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      // 'A' used in p1; later 'B' used elsewhere (more recent globally).
      await bloc.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await bloc.recordConnectionUsage(channelKey: 'B', priorityId: 'pX');

      final key = bloc.lastUsedConnectionKey(
        candidateKeys: ['A', 'B', 'plot:thread'],
        priorityId: 'p1',
      );
      expect(key, 'A');
    });

    test('falls back to the global most-recent when this priority has none',
        () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      await bloc.recordConnectionUsage(channelKey: 'A', priorityId: 'pX');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await bloc.recordConnectionUsage(channelKey: 'B', priorityId: 'pY');

      final key = bloc.lastUsedConnectionKey(
        candidateKeys: ['A', 'B'],
        priorityId: 'p1',
      );
      expect(key, 'B');
    });

    test('returns null when no candidate has a recorded use', () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      final key = bloc.lastUsedConnectionKey(
        candidateKeys: ['A', 'plot:thread'],
        priorityId: 'p1',
      );
      expect(key, isNull);
    });

    test('returns plot:thread when that was the last choice', () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      await bloc.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await bloc.recordConnectionUsage(
        channelKey: 'plot:thread',
        priorityId: 'p1',
      );

      final key = bloc.lastUsedConnectionKey(
        candidateKeys: ['A', 'plot:thread'],
        priorityId: 'p1',
      );
      expect(key, 'plot:thread');
    });
  });
}

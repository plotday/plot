import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/now.dart';

void main() {
  group('NowBlocStartStalledException.toString', () {
    test('names the single stream that wedged the bootstrap', () {
      final e = NowBlocStartStalledException(pending: const ['defaultPriority']);
      expect(
        e.toString(),
        'NowBlocStartStalledException: NowBloc.start stalled in NowLoading '
        '(pending: defaultPriority)',
      );
    });

    test('lists every outstanding stream', () {
      final e = NowBlocStartStalledException(
        pending: const ['defaultPriority', 'priorityBlocks'],
      );
      expect(
        e.toString(),
        'NowBlocStartStalledException: NowBloc.start stalled in NowLoading '
        '(pending: defaultPriority, priorityBlocks)',
      );
    });

    test('reports "none" when nothing is outstanding', () {
      final e = NowBlocStartStalledException(pending: const []);
      expect(
        e.toString(),
        'NowBlocStartStalledException: NowBloc.start stalled in NowLoading '
        '(pending: none)',
      );
    });
  });
}

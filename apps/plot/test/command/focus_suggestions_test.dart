import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/focus_suggestions.dart';

void main() {
  test('every suggestion has a non-empty key and the keys are unique', () {
    final keys = kFocusSuggestions.map((s) => s.suggestionKey).toList();
    for (final k in keys) {
      expect(k, isNotNull);
      expect(k, isNotEmpty);
    }
    expect(keys.toSet().length, keys.length, reason: 'keys must be unique');
  });

  test('visibleFocusSuggestions filters out dismissed keys, keeps order', () {
    final firstKey = kFocusSuggestions.first.suggestionKey!;
    final visible = visibleFocusSuggestions({firstKey});
    expect(visible.length, kFocusSuggestions.length - 1);
    expect(visible.any((s) => s.suggestionKey == firstKey), isFalse);
    // Order of the survivors matches the source order.
    expect(
      visible.map((s) => s.suggestionKey),
      kFocusSuggestions
          .where((s) => s.suggestionKey != firstKey)
          .map((s) => s.suggestionKey),
    );
  });

  test('visibleFocusSuggestions with no dismissals returns all', () {
    expect(visibleFocusSuggestions(const {}).length, kFocusSuggestions.length);
  });

  test('mergeDismissed appends a new key, preserving order', () {
    expect(mergeDismissed(const ['project'], 'customers'),
        ['project', 'customers']);
  });

  test('mergeDismissed is idempotent for an existing key', () {
    final existing = const ['project'];
    expect(identical(mergeDismissed(existing, 'project'), existing), isTrue);
  });
}

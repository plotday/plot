import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  test('ForwardUserAction round-trips through JSON', () {
    const action = ForwardUserAction(
      sourceTitle: 'Q3 budget review',
      sourceAuthorName: 'Alice Smith',
      quotedContent: '> Original body line 1\n> line 2',
      sourceThreadId: 'abc-123',
    );
    final json = action.toJson();
    expect(json['type'], 'forward');

    final parsed = UserAction.fromJson(json);
    expect(parsed, isA<ForwardUserAction>());
    expect((parsed as ForwardUserAction).sourceTitle, 'Q3 budget review');
    expect(parsed.quotedContent, '> Original body line 1\n> line 2');
  });
}

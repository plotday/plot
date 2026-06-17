import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_data.dart';

void main() {
  test('WidgetTodo/WidgetFocus/WidgetEvent serialize', () {
    expect(
      const WidgetTodo(threadId: 't1', title: 'Reply to sponsor').toJson(),
      {'threadId': 't1', 'title': 'Reply to sponsor'},
    );
    expect(
      const WidgetFocus(
        focusId: 'f1',
        roleName: 'AFC Marlow',
        focusName: 'Marketing',
        colorHex: '#FF0000',
      ).toJson(),
      {
        'focusId': 'f1',
        'roleName': 'AFC Marlow',
        'focusName': 'Marketing',
        'colorHex': '#FF0000',
      },
    );
    expect(
      const WidgetEvent(
        threadId: 'e1',
        title: 'Standup',
        startIso: '2026-06-17T14:00:00Z',
        endIso: '2026-06-17T14:15:00Z',
        hasCall: true,
      ).toJson(),
      {
        'threadId': 'e1',
        'title': 'Standup',
        'startIso': '2026-06-17T14:00:00Z',
        'endIso': '2026-06-17T14:15:00Z',
        'hasCall': true,
      },
    );
  });

  test('WidgetState.toJson includes new fields as lists/maps', () {
    const state = WidgetState(
      isSignedIn: true,
      userId: 'u1',
      title: 'Marketing',
      titleIsTimer: false,
      currentFocus: WidgetFocus(
        focusId: 'f1',
        roleName: null,
        focusName: 'Marketing',
        colorHex: null,
      ),
      todos: [WidgetTodo(threadId: 't1', title: 'Draft newsletter')],
      focuses: [
        WidgetFocus(
          focusId: 'f1',
          roleName: null,
          focusName: 'Marketing',
          colorHex: null,
        ),
      ],
    );
    final json = state.toJson();
    expect(json['title'], 'Marketing');
    expect(json['titleIsTimer'], false);
    expect((json['todos']! as List).single,
        {'threadId': 't1', 'title': 'Draft newsletter'});
    expect((json['currentFocus']! as Map)['focusName'], 'Marketing');
    expect((json['focuses']! as List).length, 1);
  });

  test('signedOut snapshot has empty lists, null title', () {
    final json = WidgetState.signedOut().toJson();
    expect(json['isSignedIn'], false);
    expect(json['title'], isNull);
    expect(json['todos'], isEmpty);
    expect(json['focuses'], isEmpty);
  });
}

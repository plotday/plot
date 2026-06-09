import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/status_icon_button.dart';

void main() {
  test('statusIconFor returns the status icon for a raw status string', () {
    final cfg = LinkTypeConfig.fromJson({
      'type': 'issue',
      'label': 'Issue',
      'statuses': [
        {'status': 'todo', 'label': 'Todo', 'icon': 'todo'},
        {'status': 'doing', 'label': 'Doing', 'icon': 'inProgress'},
      ],
    });
    expect(statusIconFor(cfg, 'doing'), StatusIcon.inProgress);
    expect(statusIconFor(cfg, 'todo'), StatusIcon.todo);
    expect(statusIconFor(cfg, 'unknown'), isNull);
    expect(statusIconFor(null, 'todo'), isNull);
  });
}

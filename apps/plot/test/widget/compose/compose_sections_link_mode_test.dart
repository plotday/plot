import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/compose_sections_view.dart';

void main() {
  test('LinkChipData.display prefers title, falls back to url', () {
    const withTitle = LinkChipData(url: 'https://x.com/a', title: 'Hello');
    const noTitle = LinkChipData(url: 'https://x.com/a');
    expect(withTitle.display, 'Hello');
    expect(noTitle.display, 'https://x.com/a');
    const emptyTitle = LinkChipData(url: 'https://x.com/a', title: '');
    expect(emptyTitle.display, 'https://x.com/a');
  });
}

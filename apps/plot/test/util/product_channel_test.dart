import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/product_channel.dart';

void main() {
  test('productKeyOf returns prefix before first colon', () {
    expect(productKeyOf('calendar:primary'), 'calendar');
    expect(productKeyOf('mail:Label_42'), 'mail');
    // raw id may itself contain colons — only the first split matters
    expect(productKeyOf('calendar:user@x.com:primary'), 'calendar');
    expect(productKeyOf('nocolon'), isNull);
  });

  test('rawChannelId strips the product prefix (keeps remaining colons)', () {
    expect(rawChannelId('calendar:user@x.com:primary'), 'user@x.com:primary');
    expect(rawChannelId('nocolon'), 'nocolon');
  });
}

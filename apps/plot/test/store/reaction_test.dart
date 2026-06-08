import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  test('null/absent → open (any emoji allowed)', () {
    expect(reactionCapabilitiesFromJson(null).allowed, isNull);
    expect(reactionCapabilitiesFromJson({}).allowed, isNull);
  });
  test('open-unicode → allowed is null (unfiltered)', () {
    expect(reactionCapabilitiesFromJson({'mode': 'open-unicode'}).allowed, isNull);
  });
  test('fixed → allowed is the declared set', () {
    expect(
      reactionCapabilitiesFromJson({'mode': 'fixed', 'allowed': ['👍', '❤️']}).allowed,
      ['👍', '❤️'],
    );
  });
  test('unicode-subset with subset → allowed is the subset', () {
    expect(
      reactionCapabilitiesFromJson({'mode': 'unicode-subset', 'subset': ['👍']}).allowed,
      ['👍'],
    );
  });
  test('unicode-subset without subset → open (null allowed)', () {
    expect(reactionCapabilitiesFromJson({'mode': 'unicode-subset'}).allowed, isNull);
  });
}

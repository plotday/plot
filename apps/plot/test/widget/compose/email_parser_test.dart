import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/email_parser.dart';

void main() {
  group('EmailParser.isEmail', () {
    test('plain address', () {
      expect(EmailParser.isEmail('alice@example.com'), isTrue);
    });

    test('plus-addressed', () {
      expect(EmailParser.isEmail('alice+filter@example.com'), isTrue);
    });

    test('subdomain', () {
      expect(EmailParser.isEmail('alice@mail.example.co.uk'), isTrue);
    });

    test('rejects missing tld', () {
      expect(EmailParser.isEmail('alice@example'), isFalse);
    });

    test('rejects missing @', () {
      expect(EmailParser.isEmail('aliceexample.com'), isFalse);
    });

    test('rejects whitespace', () {
      expect(EmailParser.isEmail('alice @example.com'), isFalse);
    });

    test('trims leading/trailing whitespace', () {
      expect(EmailParser.isEmail('  alice@example.com  '), isTrue);
    });

    test('returns trimmed value via normalize', () {
      expect(
        EmailParser.normalize('  alice@example.com  '),
        'alice@example.com',
      );
    });
  });
}

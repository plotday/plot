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

  group('EmailParser.parseRecipients', () {
    test('single bare email', () {
      final r = EmailParser.parseRecipients('kris@plot.day');
      expect(r, hasLength(1));
      expect(r.single.email, 'kris@plot.day');
      expect(r.single.name, isNull);
    });

    test('comma / semicolon / space separated', () {
      for (final input in [
        'a@x.com, b@y.com',
        'a@x.com; b@y.com',
        'a@x.com b@y.com',
        ' a@x.com ,;  b@y.com ',
      ]) {
        final r = EmailParser.parseRecipients(input);
        expect(r.map((e) => e.email), ['a@x.com', 'b@y.com'], reason: input);
        expect(r.every((e) => e.name == null), isTrue, reason: input);
      }
    });

    test('Name <email> form captures the name', () {
      final r = EmailParser.parseRecipients('Kris Braun <kris@plot.day>');
      expect(r.single.email, 'kris@plot.day');
      expect(r.single.name, 'Kris Braun');
    });

    test('quoted name is unquoted', () {
      final r = EmailParser.parseRecipients('"Braun, Kris" <kris@plot.day>');
      expect(r.single.name, 'Braun, Kris');
      expect(r.single.email, 'kris@plot.day');
    });

    test('mixed named and bare, multiple separators', () {
      final r = EmailParser.parseRecipients(
        'Kris Braun <kris@plot.day>, dana@acme.co; sam@x.io',
      );
      expect(r.map((e) => e.email), ['kris@plot.day', 'dana@acme.co', 'sam@x.io']);
      expect(r[0].name, 'Kris Braun');
      expect(r[1].name, isNull);
      expect(r[2].name, isNull);
    });

    test('non-email junk yields no recipients', () {
      expect(EmailParser.parseRecipients('Kris Braun'), isEmpty);
      expect(EmailParser.parseRecipients('hello world'), isEmpty);
      expect(EmailParser.parseRecipients(''), isEmpty);
    });

    test('isEmailQuery true only when at least one email parses', () {
      expect(EmailParser.isEmailQuery('a@x.com b@y.com'), isTrue);
      expect(EmailParser.isEmailQuery('Greg'), isFalse);
    });

    test('emails are lower-cased and trimmed', () {
      final r = EmailParser.parseRecipients('KRIS@Plot.Day');
      expect(r.single.email, 'kris@plot.day');
    });
  });

  group('InviteAddress', () {
    test('format with name', () {
      expect(InviteAddress.format(email: 'k@x.com', name: 'Kris Braun'),
          'Kris Braun <k@x.com>');
    });
    test('format without name is bare', () {
      expect(InviteAddress.format(email: 'k@x.com', name: null), 'k@x.com');
      expect(InviteAddress.format(email: 'k@x.com', name: ''), 'k@x.com');
    });
    test('parse named', () {
      final a = InviteAddress.parse('Kris Braun <k@x.com>');
      expect(a.email, 'k@x.com');
      expect(a.name, 'Kris Braun');
    });
    test('parse bare', () {
      final a = InviteAddress.parse('k@x.com');
      expect(a.email, 'k@x.com');
      expect(a.name, isNull);
    });
    test('round-trips', () {
      for (final s in ['k@x.com', 'Kris Braun <k@x.com>']) {
        final a = InviteAddress.parse(s);
        expect(InviteAddress.format(email: a.email, name: a.name), s);
      }
    });
  });
}

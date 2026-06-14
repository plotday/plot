import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  test('Cta round-trips through json', () {
    const cta = Cta(kind: CtaKind.otp, service: 'Acme', code: '123456', url: null);
    expect(Cta.fromJson(cta.toJson()), cta);
  });
  test('confirm cta parses', () {
    final cta = Cta.fromJson({
      'kind': 'confirm', 'service': 'Acme', 'code': null, 'url': 'https://a/c',
    });
    expect(cta.kind, CtaKind.confirm);
    expect(cta.url, 'https://a/c');
  });
  test('CtaConverter round-trips via SQL (text)', () {
    const c = CtaConverter();
    const cta = Cta(
      kind: CtaKind.confirm,
      service: 'Acme',
      code: null,
      url: 'https://a/c',
    );
    expect(c.fromSql(c.toSql(cta)), cta);
    expect(c.fromSql(null), isNull);
    expect(c.toSql(null), isNull);
  });
  test('CtaConverter parses a sync JSON object (the path that was broken)', () {
    const c = CtaConverter();
    final cta = c.fromJson({
      'kind': 'otp',
      'service': 'Acme',
      'code': '123456',
      'url': null,
    });
    expect(
      cta,
      const Cta(
        kind: CtaKind.otp,
        service: 'Acme',
        code: '123456',
        url: null,
      ),
    );
    expect(c.fromJson(null), isNull);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/string_list_converter.dart';

void main() {
  const c = StringListConverter();

  test('SQL round-trip preserves order', () {
    expect(c.toSql(const ['project', 'customers']), 'project,customers');
    expect(c.fromSql('project,customers'), ['project', 'customers']);
  });

  test('empty string decodes to an empty list', () {
    expect(c.fromSql(''), isEmpty);
    expect(c.toSql(const []), '');
  });

  test('JSON (sync) round-trip uses a list of strings', () {
    expect(c.toJson(const ['project']), ['project']);
    expect(c.fromJson(<dynamic>['project', 'customers']),
        ['project', 'customers']);
  });
}

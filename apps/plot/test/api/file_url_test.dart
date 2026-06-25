import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/file_url.dart';

void main() {
  test('no width yields a plain /files/<id> url', () {
    final uri = buildFileBytesUri('https://api.example', 'abc-123');
    expect(uri.toString(), 'https://api.example/files/abc-123');
    expect(uri.queryParameters.containsKey('w'), isFalse);
  });

  test('width adds a ?w query param', () {
    final uri = buildFileBytesUri('https://api.example', 'abc-123', width: 800);
    expect(uri.path, '/files/abc-123');
    expect(uri.queryParameters['w'], '800');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:plot/page/loading.dart';

void main() {
  group('StuckLoadingPageException.toString', () {
    test('with no detail, reports the bare 60s message', () {
      final e = StuckLoadingPageException(
        message: null,
        userStatus: null,
        route: null,
      );
      expect(e.toString(), 'StuckLoadingPageException: LoadingPage still visible after 60s');
    });

    test('includes the route so a stuck placeholder is diagnosable', () {
      final e = StuckLoadingPageException(
        message: null,
        userStatus: null,
        route: '/p/CXH9QUq4zFmvTopn1i8Xv',
      );
      expect(
        e.toString(),
        'StuckLoadingPageException: LoadingPage still visible after 60s '
        '(route="/p/CXH9QUq4zFmvTopn1i8Xv")',
      );
    });

    test('includes message, userStatus, and route together', () {
      final e = StuckLoadingPageException(
        message: 'Plotting your success…',
        userStatus: 'Signing in...',
        route: '/',
      );
      expect(
        e.toString(),
        'StuckLoadingPageException: LoadingPage still visible after 60s '
        '(message="Plotting your success…", userStatus="Signing in...", route="/")',
      );
    });
  });
}

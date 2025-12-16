export 'package:remove_markdown/remove_markdown.dart';

extension StringExtension on String {
  /// Truncates the string to the specified [length].
  ///
  /// If the string is longer than [length], returns a string of exactly [length]
  /// with the final character replaced by an ellipsis (…).
  ///
  /// Examples:
  /// ```dart
  /// 'Hello World'.truncate(5)  // 'Hell…'
  /// 'Hi'.truncate(5)           // 'Hi'
  /// 'Test'.truncate(4)         // 'Test'
  /// ```
  String truncate(int length) {
    if (this.length <= length) {
      return this;
    }

    if (length <= 0) {
      return '';
    }

    return '${substring(0, length - 1)}…';
  }
}

/// Lenient email pattern matcher for compose-field chip commits. Not for
/// validating mail-routable addresses — chips with addresses that don't
/// actually deliver are surfaced as bounces server-side.
class EmailParser {
  static final RegExp _pattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  /// True iff [value] (after trimming) matches the address pattern.
  static bool isEmail(String value) => _pattern.hasMatch(value.trim());

  /// Trimmed form of [value].
  static String normalize(String value) => value.trim();
}

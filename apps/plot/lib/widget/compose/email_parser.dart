/// One parsed recipient from a compose query: a normalized email plus an
/// optional display name captured from the `Name <email>` form.
class ParsedRecipient {
  const ParsedRecipient({required this.email, this.name});
  final String email;
  final String? name;
}

/// Lenient email parsing for compose-field input. Not for validating
/// mail-routable addresses — bad addresses surface as bounces server-side.
class EmailParser {
  static final RegExp _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  // "Display Name <email>"; the email is inside the angle brackets.
  static final RegExp _named = RegExp(r'^(.*)<([^>]+)>$');
  static final RegExp _whitespace = RegExp(r'\s+');

  /// True iff [value] (after trimming) is a single address.
  static bool isEmail(String value) => _email.hasMatch(value.trim());

  /// True iff [value] parses to at least one recipient (email mode).
  static bool isEmailQuery(String value) => parseRecipients(value).isNotEmpty;

  /// Trimmed form of [value]. Retained for callers that still want it.
  static String normalize(String value) => value.trim();

  /// Parse [input] into recipients. Splits on commas/semicolons that are not
  /// inside double-quotes or angle brackets; each segment is either a
  /// `Name <email>` form or one-or-more whitespace-separated bare emails.
  /// Non-email tokens are dropped. Returns [] when nothing parses (the caller
  /// then treats the query as a name search).
  static List<ParsedRecipient> parseRecipients(String input) {
    final out = <ParsedRecipient>[];
    for (final rawSegment in _splitRecipients(input)) {
      final segment = rawSegment.trim();
      if (segment.isEmpty) continue;
      final named = _named.firstMatch(segment);
      if (named != null) {
        final email = named.group(2)!.trim(); // trimmed before the email check
        if (!_email.hasMatch(email)) continue;
        final name = _unquote(named.group(1)!.trim());
        out.add(ParsedRecipient(
          email: email.toLowerCase(),
          name: name.isEmpty ? null : name,
        ));
        continue;
      }
      for (final token in segment.split(_whitespace)) {
        final t = token.trim();
        if (_email.hasMatch(t)) {
          out.add(ParsedRecipient(email: t.toLowerCase()));
        }
      }
    }
    return out;
  }

  /// Split [input] on commas and semicolons that are not inside double-quoted
  /// strings or angle-bracket groups (e.g. `"Braun, Kris" <email>` must not
  /// be split at the comma inside the quotes).
  static List<String> _splitRecipients(String input) {
    final segments = <String>[];
    final buf = StringBuffer();
    var inQuote = false;
    var inAngle = 0;
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == '"') {
        inQuote = !inQuote;
        buf.write(ch);
      } else if (ch == '<' && !inQuote) {
        inAngle++;
        buf.write(ch);
      } else if (ch == '>' && !inQuote) {
        if (inAngle > 0) inAngle--;
        buf.write(ch);
      } else if ((ch == ',' || ch == ';') && !inQuote && inAngle == 0) {
        segments.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    segments.add(buf.toString());
    return segments;
  }

  static String _unquote(String s) {
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      return s.substring(1, s.length - 1).trim();
    }
    return s;
  }
}

/// Wire encoding for a pending email invitation that optionally carries a
/// display name. Encoded as RFC-style `"Name <email>"` (or the bare email when
/// nameless) inside the existing `inviteEmails` string list — so no schema or
/// sync change is needed. The server parses the same form before
/// `upsert_contacts` to create a *named* contact.
class InviteAddress {
  const InviteAddress({required this.email, this.name});
  final String email;
  final String? name;

  static String format({required String email, String? name}) =>
      (name != null && name.trim().isNotEmpty)
          ? '${name.trim()} <$email>'
          : email;

  static InviteAddress parse(String encoded) {
    final r = EmailParser.parseRecipients(encoded);
    if (r.isNotEmpty) return InviteAddress(email: r.first.email, name: r.first.name);
    // Defensive fallback for non-email-shaped input; lowercase to match the
    // normalization the parse path applies above.
    return InviteAddress(email: encoded.trim().toLowerCase());
  }
}

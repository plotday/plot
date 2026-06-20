/// Pure helpers for the never-lose-drafts feature. No store / Flutter imports
/// so they unit-test in isolation (see test/util/draft_test.dart).
library;

/// Whether a draft holds user content worth keeping and listing. A draft with
/// none of these is a "skeleton" the page minted to compose into; it is never
/// listed (active or archived).
bool isSubstantiveDraftFields({
  required String? title,
  required bool hasRecipients,
  required bool hasSchedule,
  required String? body,
  required bool hasActions,
}) {
  if ((title?.trim().isNotEmpty ?? false)) return true;
  if (hasRecipients) return true;
  if (hasSchedule) return true;
  if ((body?.trim().isNotEmpty ?? false)) return true;
  if (hasActions) return true;
  return false;
}

/// The first non-empty line of [content], trimmed and truncated to [maxLen]
/// (with a trailing ellipsis when truncated). Null when there is no text.
String? draftBodySnippet(String? content, {int maxLen = 80}) {
  if (content == null) return null;
  for (final raw in content.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.length <= maxLen) return line;
    return '${line.substring(0, maxLen)}…';
  }
  return null;
}

/// The tile label for a draft: title → body snippet → recipient summary →
/// "Untitled draft". Inputs are pre-resolved by the caller.
String draftPrimaryLabel({
  required String? title,
  required String? bodySnippet,
  required String? recipientSummary,
}) {
  final t = title?.trim();
  if (t != null && t.isNotEmpty) return t;
  final b = bodySnippet?.trim();
  if (b != null && b.isNotEmpty) return b;
  final r = recipientSummary?.trim();
  if (r != null && r.isNotEmpty) return r;
  return 'Untitled draft';
}

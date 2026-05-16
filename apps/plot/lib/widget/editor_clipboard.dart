import 'dart:convert';

import 'package:flutter/services.dart' show Uint8List;
import 'package:super_clipboard/super_clipboard.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:html2md/html2md.dart' as html2md;
import 'package:remove_markdown/remove_markdown.dart';

/// Custom clipboard format for lossless Plot-to-Plot copy/paste.
/// Uses the `day.plot.markdown` UTI on macOS/iOS, and equivalent
/// MIME-type-based identifiers on other platforms.
///
/// Contains Plot markdown with mentions in `[Name](#@UUID)` format,
/// which is the internal storage format for notes.
const plotMarkdownFormat = CustomValueFormat<Uint8List>(
  applicationId: 'day.plot.markdown',
);

/// Regex matching mention syntax in Plot markdown: [Name](#@UUID)
final _mentionPattern = RegExp(
  r'\[([^\]]+)\]\(#@[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\)',
);

/// Write multi-format clipboard data: Plot markdown, HTML, and plain text.
///
/// [plotMarkdown] is the internal Plot markdown (with mention syntax).
/// If null, only HTML and plain text are written.
Future<void> writeClipboard({
  required String? plotMarkdown,
  required String plainText,
  String? html,
}) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return;

  final item = DataWriterItem();

  // Highest fidelity first: Plot markdown for lossless intra-app paste
  if (plotMarkdown != null) {
    item.add(plotMarkdownFormat(Uint8List.fromList(utf8.encode(plotMarkdown))));
  }

  // HTML for rich paste into other apps
  if (html != null) {
    item.add(Formats.htmlText(html));
  }

  // Plain text fallback (always include — required on some platforms)
  item.add(Formats.plainText(plainText));

  await clipboard.write([item]);
}

/// Convert Plot markdown to HTML for clipboard.
/// Strips mention `[Name](#@UUID)` syntax to just `Name` before conversion,
/// so HTML output shows clean display names.
String markdownToHtml(String plotMarkdown) {
  // Strip mention syntax: [Name](#@UUID) → Name
  final cleanMarkdown = plotMarkdown.replaceAllMapped(
    _mentionPattern,
    (match) => match.group(1) ?? '',
  );
  return md.markdownToHtml(cleanMarkdown);
}

/// Convert Plot markdown to plain text for clipboard.
/// Strips all markdown syntax including mention references, but keeps a
/// `-` marker on each list item so the list structure survives a paste
/// into apps that only consume plain text.
String markdownToPlainText(String plotMarkdown) {
  // Strip mention syntax first: [Name](#@UUID) → Name
  final cleanMarkdown = plotMarkdown.replaceAllMapped(
    _mentionPattern,
    (match) => match.group(1) ?? '',
  );
  return cleanMarkdown.removeMarkdown(listUnicodeChar: '-');
}

/// Convert HTML from clipboard to Plot markdown for paste.
String htmlToMarkdown(String html) {
  final markdown = html2md.convert(html);
  // Strip links whose visible text would be empty after the deserializer
  // extracts inline images into their own nodes. Otherwise super_editor
  // calls `addAttribution(LinkAttribution, SpanRange(0, -1))` and warns.
  // Covers: `[](url)`, `[ ](url)`, and `[![alt](img)](url)` (the form
  // html2md emits for `<a href="X"><img></a>` — common in email footers).
  return markdown.replaceAll(_emptyLinkPattern, '');
}

final _emptyLinkPattern = RegExp(
  r'\[(?:\s*!\[[^\]]*\]\([^)]*\))*\s*\]\([^)]*\)',
);

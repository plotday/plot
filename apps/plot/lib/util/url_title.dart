import 'package:http/http.dart' as http;

/// Fetches the <title> tag from a URL's HTML.
/// Returns null on any failure (timeout, parse error, non-HTML, etc.).
Future<String?> fetchUrlTitle(String url) async {
  try {
    final uri = Uri.parse(url);
    final response = await http.get(uri).timeout(
      const Duration(seconds: 5),
    );
    if (response.statusCode != 200) return null;

    // Extract <title>...</title> content
    final match = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(response.body);
    if (match == null) return null;

    var title = match.group(1)?.trim();
    if (title == null || title.isEmpty) return null;

    // Decode common HTML entities
    title = title
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll('&nbsp;', ' ');

    // Collapse whitespace (titles can span multiple lines in source)
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();

    return title.isEmpty ? null : title;
  } catch (_) {
    return null;
  }
}

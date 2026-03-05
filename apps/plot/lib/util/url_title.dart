import 'package:http/http.dart' as http;

/// Metadata extracted from a URL's HTML page.
typedef UrlMetadata = ({String? title, String? favicon});

/// Fetches the <title> and favicon from a URL's HTML.
/// Returns nulls on any failure (timeout, parse error, non-HTML, etc.).
Future<UrlMetadata> fetchUrlMetadata(String url) async {
  try {
    final uri = Uri.parse(url);
    final response = await http.get(uri).timeout(
      const Duration(seconds: 5),
    );
    if (response.statusCode != 200) return (title: null, favicon: null);

    final body = response.body;

    // Extract <title>...</title> content
    String? title;
    final titleMatch = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(body);
    if (titleMatch != null) {
      title = titleMatch.group(1)?.trim();
      if (title != null && title.isNotEmpty) {
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
        if (title.isEmpty) title = null;
      } else {
        title = null;
      }
    }

    // Extract favicon URL from <link> tags
    String? favicon;
    final faviconMatch = RegExp(
      r'''<link[^>]*\brel\s*=\s*["'](?:icon|shortcut icon|apple-touch-icon)["'][^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*/?>''',
      caseSensitive: false,
    ).firstMatch(body);
    // Also try the reverse attribute order (href before rel)
    final faviconMatch2 = faviconMatch ?? RegExp(
      r'''<link[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*\brel\s*=\s*["'](?:icon|shortcut icon|apple-touch-icon)["'][^>]*/?>''',
      caseSensitive: false,
    ).firstMatch(body);

    if (faviconMatch2 != null) {
      final href = faviconMatch2.group(1);
      if (href != null && href.isNotEmpty) {
        favicon = uri.resolve(href).toString();
      }
    }

    // Fall back to /favicon.ico
    favicon ??= uri.resolve('/favicon.ico').toString();

    return (title: title, favicon: favicon);
  } catch (_) {
    return (title: null, favicon: null);
  }
}

/// Fetches the <title> tag from a URL's HTML.
/// Returns null on any failure (timeout, parse error, non-HTML, etc.).
Future<String?> fetchUrlTitle(String url) async {
  final metadata = await fetchUrlMetadata(url);
  return metadata.title;
}

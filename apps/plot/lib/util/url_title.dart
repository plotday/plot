import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:plot/api/api.dart' show getHeaders;
import 'package:plot/env.dart';

/// Metadata extracted from a URL's HTML page.
typedef UrlMetadata = ({String? title, String? favicon});

/// Fetches the title and favicon for [url] via the Plot API.
///
/// The server handles per-host special cases (Reddit, YouTube, Twitter/X,
/// Vimeo, Spotify) and the generic HTML scrape — needed because the Flutter
/// web client can't fetch arbitrary cross-origin pages from the browser, and
/// because many sites block default fetch User-Agents. Returns nulls on any
/// failure (timeout, network error, server error, etc.).
Future<UrlMetadata> fetchUrlMetadata(String url) async {
  try {
    final endpoint = Uri.parse(
      '${Env.apiRoot}/metadata?url=${Uri.encodeComponent(url)}',
    );
    final headers = await getHeaders();
    final response = await http
        .get(endpoint, headers: headers)
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return (title: null, favicon: null);

    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final dynamic decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return (title: null, favicon: null);

    final title = decoded['title'];
    final favicon = decoded['favicon'];
    return (
      title: title is String && title.isNotEmpty ? title : null,
      favicon: favicon is String && favicon.isNotEmpty ? favicon : null,
    );
  } catch (_) {
    return (title: null, favicon: null);
  }
}

/// Fetches just the title for [url].
Future<String?> fetchUrlTitle(String url) async {
  final metadata = await fetchUrlMetadata(url);
  return metadata.title;
}

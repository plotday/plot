import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:share_handler/share_handler.dart';
import 'package:logging/logging.dart';

final _log = Logger('plot.share_intent');

/// Holds a pending shared URL until the app is ready to handle it.
class PendingShare {
  static String? url;
}

/// Initializes share intent handling for iOS and Android.
/// Returns a StreamSubscription that should be kept alive for the app's lifetime.
StreamSubscription<SharedMedia>? initShareIntent({
  required void Function(String url) onShareReceived,
}) {
  if (kIsWeb || !(Platform.isIOS || Platform.isAndroid)) return null;

  final handler = ShareHandlerPlatform.instance;

  // Check for initial shared content (cold start)
  handler.getInitialSharedMedia().then((SharedMedia? media) {
    final url = _extractUrl(media);
    if (url != null) {
      _log.info('App opened with shared URL: $url');
      onShareReceived(url);
    }
  }).catchError((Object error) {
    _log.warning('Failed to get initial shared media: $error');
  });

  // Listen for shares while app is running (warm start)
  return handler.sharedMediaStream.listen(
    (SharedMedia media) {
      final url = _extractUrl(media);
      if (url != null) {
        _log.info('Received shared URL: $url');
        onShareReceived(url);
      }
    },
    onError: (Object error) {
      _log.warning('Share intent stream error: $error');
    },
  );
}

/// Extracts an HTTP/HTTPS URL from shared media content.
String? _extractUrl(SharedMedia? media) {
  if (media == null) return null;
  final content = media.content?.trim();
  if (content == null || content.isEmpty) return null;

  // Check if the shared text is a URL
  if (_isHttpUrl(content)) return content;

  // Some apps share URLs in "Title\nURL" format — extract the URL
  final lines = content.split('\n');
  for (final line in lines) {
    final trimmed = line.trim();
    if (_isHttpUrl(trimmed)) return trimmed;
  }

  return null;
}

bool _isHttpUrl(String text) {
  final uri = Uri.tryParse(text);
  return uri != null &&
      uri.hasScheme &&
      (uri.scheme == 'http' || uri.scheme == 'https');
}

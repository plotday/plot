import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:share_handler/share_handler.dart';
import 'package:logging/logging.dart';

final _log = Logger('plot.share_intent');

/// Holds a pending shared URL until the app is ready to handle it.
///
/// On cold start, [onReady] is set by the router once it can handle navigation.
/// If a URL arrives before [onReady] is set, it's buffered and replayed.
class PendingShare {
  static String? _url;
  static void Function(String url)? _onReady;

  static String? get url => _url;

  static set url(String? value) {
    if (value != null && _onReady != null) {
      _log.info(
        'PendingShare: url received, onReady already set — dispatching immediately',
      );
      _onReady!(value);
      _onReady = null;
    } else {
      _log.info(
        'PendingShare: url buffered (onReady not yet set): ${value != null}',
      );
      _url = value;
    }
  }

  /// Register a callback for when a pending share URL is ready.
  /// If one is already buffered, it replays immediately.
  static set onReady(void Function(String url)? callback) {
    _onReady = callback;
    if (callback != null && _url != null) {
      _log.info(
        'PendingShare: onReady registered with buffered URL — replaying',
      );
      final buffered = _url!;
      _url = null;
      callback(buffered);
    } else {
      _log.info(
        'PendingShare: onReady ${callback == null ? "cleared" : "registered (no buffered URL)"}',
      );
    }
  }
}

/// Initializes share intent handling for iOS and Android.
/// Returns a StreamSubscription that should be kept alive for the app's lifetime.
StreamSubscription<SharedMedia>? initShareIntent({
  required void Function(String url) onShareReceived,
}) {
  if (kIsWeb || !(Platform.isIOS || Platform.isAndroid)) {
    _log.info('initShareIntent: skipped (not iOS/Android)');
    return null;
  }

  _log.info('initShareIntent: initializing on ${Platform.operatingSystem}');
  final handler = ShareHandlerPlatform.instance;

  // Check for initial shared content (cold start)
  handler
      .getInitialSharedMedia()
      .then((SharedMedia? media) {
        _log.info(
          'getInitialSharedMedia resolved: media=${media != null}, '
          'content=${media?.content != null ? "<${media!.content!.length} chars>" : "null"}, '
          'attachments=${media?.attachments?.length ?? 0}',
        );
        final url = _extractUrl(media);
        if (url != null) {
          _log.info('Cold-start shared URL detected: $url');
          onShareReceived(url);
        } else if (media != null) {
          _log.warning(
            'Cold-start shared media had no extractable URL: content=${media.content}',
          );
        }
      })
      .catchError((Object error) {
        _log.warning('Failed to get initial shared media: $error');
      });

  // Listen for shares while app is running (warm start)
  return handler.sharedMediaStream.listen(
    (SharedMedia media) {
      _log.info(
        'sharedMediaStream event: content=${media.content != null ? "<${media.content!.length} chars>" : "null"}, '
        'attachments=${media.attachments?.length ?? 0}',
      );
      final url = _extractUrl(media);
      if (url != null) {
        _log.info('Stream-received shared URL: $url');
        onShareReceived(url);
      } else {
        _log.warning(
          'Stream-received media had no extractable URL: content=${media.content}',
        );
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
  return extractHttpUrl(media.content);
}

/// Extracts an HTTP/HTTPS URL from a raw shared text blob. Handles plain URLs
/// as well as "Title\nURL" formats used by some share sources.
String? extractHttpUrl(String? raw) {
  final content = raw?.trim();
  if (content == null || content.isEmpty) return null;

  if (_isHttpUrl(content)) return content;

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

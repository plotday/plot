import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart';

/// Result of a [downloadFile] call. See `download_stub.dart` for full docs.
class DownloadResult {
  const DownloadResult({
    required this.success,
    this.savedPath,
    this.destinationLabel,
  });

  final bool success;
  final String? savedPath;
  final String? destinationLabel;

  static const cancelled = DownloadResult(success: false);
}

/// Triggers a browser download of [bytes] with [fileName] as the suggested name.
Future<DownloadResult> downloadFile({
  required Uint8List bytes,
  required String fileName,
  String? mimeType,
}) async {
  final blob = Blob(
    [bytes.toJS].toJS,
    BlobPropertyBag(type: mimeType ?? 'application/octet-stream'),
  );
  final url = URL.createObjectURL(blob);
  final anchor = document.createElement('a') as HTMLAnchorElement
    ..href = url
    ..download = fileName;
  document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
  return const DownloadResult(success: true);
}

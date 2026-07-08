import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Writes [bytes] to a temp file named [fileName] and opens it with the
/// platform's default handler, so the user sees the attachment in the
/// appropriate viewer.
///
/// Mobile (Android/iOS): opens via [OpenFilex], which routes through a
/// FileProvider / document-interaction controller. A raw `file://` launch is
/// rejected on Android (API 24+ `FileUriExposedException`) and unsupported on
/// iOS, so [OpenFilex] — not [launchUrl] — must be used there.
///
/// Desktop (macOS/Windows/Linux): hands the file to the OS via
/// `launchUrl(Uri.file(...))` (Launch Services / xdg-open).
///
/// Throws [OpenFileException] on failure so callers can surface an error toast.
Future<void> openFileBytes({
  required Uint8List bytes,
  required String fileName,
  String? mimeType,
}) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes);

  if (Platform.isAndroid || Platform.isIOS) {
    final result = await OpenFilex.open(file.path, type: mimeType);
    if (result.type != ResultType.done) {
      throw OpenFileException(
        'Could not open $fileName: ${result.type} (${result.message})',
      );
    }
    return;
  }

  final launched = await launchUrl(Uri.file(file.path));
  if (!launched) {
    throw OpenFileException('launchUrl returned false for ${file.path}');
  }
}

/// Thrown when the platform could not open a downloaded file.
class OpenFileException implements Exception {
  OpenFileException(this.message);

  final String message;

  @override
  String toString() => 'OpenFileException: $message';
}

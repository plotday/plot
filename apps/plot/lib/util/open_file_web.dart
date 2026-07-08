import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [bytes] in the browser by encoding them as a `data:` URL and launching
/// it in a new tab.
///
/// [fileName] is unused on web (the browser derives handling from the MIME
/// type) but kept for a uniform cross-platform signature with the native
/// implementation in `open_file_io.dart`.
Future<void> openFileBytes({
  required Uint8List bytes,
  required String fileName,
  String? mimeType,
}) async {
  final blob = Uri.dataFromBytes(
    bytes,
    mimeType: mimeType ?? 'application/octet-stream',
  );
  await launchUrl(blob);
}

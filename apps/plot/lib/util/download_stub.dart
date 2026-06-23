import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Result of a [downloadFile] call.
///
/// On desktop, [savedPath] is the absolute file path. On iOS/Android,
/// [savedPath] is whatever path the system picker reported (often a transient
/// or sandboxed path that's not user-meaningful) — prefer [destinationLabel]
/// for display. On web, both are null.
class DownloadResult {
  const DownloadResult({
    required this.success,
    this.savedPath,
    this.destinationLabel,
  });

  final bool success;
  final String? savedPath;

  /// Human-readable description of where the file was saved (e.g.
  /// "Downloads"). Null on web (the browser handles destination).
  final String? destinationLabel;

  static const cancelled = DownloadResult(success: false);
}

/// Saves [bytes] with [fileName] as the proposed name.
///
/// On Windows / Linux: writes directly to the user's Downloads folder without
/// prompting, suffixing the filename if one already exists.
/// On macOS: shows the native save panel. The macOS App Store build is
/// sandboxed, and saving via the panel grants write access to the chosen
/// location through the powerbox — so we don't need the broad
/// `com.apple.security.files.downloads.read-write` entitlement (removed per
/// App Review guideline 2.4.5: minimum entitlements only).
/// On iOS / Android: shows the native save picker (no shared "Downloads"
/// concept on iOS, and Android Downloads requires MediaStore).
Future<DownloadResult> downloadFile({
  required Uint8List bytes,
  required String fileName,
  String? mimeType,
}) async {
  if (Platform.isIOS || Platform.isAndroid) {
    final path = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
    );
    if (path == null) return DownloadResult.cancelled;
    return DownloadResult(success: true, savedPath: path);
  }

  if (Platform.isMacOS) {
    // Sandboxed: let the user pick the destination via the save panel. The
    // panel returns a path we're granted write access to; we write the bytes
    // ourselves. No destinationLabel — the user chose where it went.
    final path = await FilePicker.saveFile(fileName: fileName);
    if (path == null) return DownloadResult.cancelled;
    await File(path).writeAsBytes(bytes);
    return DownloadResult(success: true, savedPath: path);
  }

  // Windows / Linux: not sandboxed — save directly to ~/Downloads.
  final dir = await getDownloadsDirectory();
  if (dir == null) {
    // Fall back to a save dialog if the platform doesn't expose Downloads.
    final path = await FilePicker.saveFile(fileName: fileName);
    if (path == null) return DownloadResult.cancelled;
    await File(path).writeAsBytes(bytes);
    return DownloadResult(success: true, savedPath: path);
  }

  final target = await _uniquePath(dir, fileName);
  await File(target).writeAsBytes(bytes);
  return DownloadResult(
    success: true,
    savedPath: target,
    destinationLabel: 'Downloads',
  );
}

/// Returns a path inside [dir] for [fileName] that does not collide with an
/// existing file. Adds " (1)", " (2)", … before the extension if needed.
Future<String> _uniquePath(Directory dir, String fileName) async {
  final dot = fileName.lastIndexOf('.');
  final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  final ext = dot > 0 ? fileName.substring(dot) : '';
  final sep = Platform.pathSeparator;
  var candidate = '${dir.path}$sep$fileName';
  var n = 1;
  while (await File(candidate).exists()) {
    candidate = '${dir.path}$sep$stem ($n)$ext';
    n++;
  }
  return candidate;
}

import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/attachment_uploader.dart';
import 'package:plot/widget/widget.dart' hide Link;

const _maxFileSize = 25 * 1024 * 1024; // 25MB

/// Builds a [LocalAttachment] from a picked [PlatformFile]. Reads image bytes on
/// native so the editor can render the thumbnail immediately from local data;
/// non-image native files stream from their path during upload.
Future<LocalAttachment> _toLocalAttachment(PlatformFile file) async {
  final mimeType = lookupMimeType(file.name) ?? 'application/octet-stream';
  final isImage = mimeType.startsWith('image/');

  Uint8List? bytes;
  String? filePath;
  if (kIsWeb) {
    bytes = file.bytes;
  } else {
    filePath = file.path;
    if (isImage && filePath != null) {
      bytes = await File(filePath).readAsBytes();
    }
  }

  return LocalAttachment(
    fileName: file.name,
    mimeType: mimeType,
    fileSize: file.size,
    bytes: bytes,
    filePath: filePath,
  );
}

/// Picks one or more files and hands them to the editor as [LocalAttachment]s.
/// The editor inserts a preview immediately and uploads in the background, so
/// this command returns as soon as the files are selected.
class AttachFile extends Command {
  AttachFile({required this.onAttach})
      : super(
          title: 'Attach file',
          eventObject: EventObject.note,
          eventAction: EventAction.added,
          icon: PlotIcon.attachment,
        );

  final void Function(List<LocalAttachment> attachments) onAttach;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // `withData: kIsWeb` is required on web: there is no filesystem path, so the
    // bytes are read from `file.bytes`. Without it the picker leaves `bytes`
    // null (it stores a data-URL in `path` instead). Native keeps `withData`
    // off so it streams from the path rather than copying the whole file into
    // memory.
    final result =
        await FilePicker.pickFiles(allowMultiple: true, withData: kIsWeb);
    if (result == null || result.files.isEmpty) {
      return const CommandSkipped();
    }

    final skipped = <String>[];
    final attachments = <LocalAttachment>[];

    for (final file in result.files) {
      if (file.size > _maxFileSize) {
        skipped.add(file.name);
        continue;
      }
      attachments.add(await _toLocalAttachment(file));
    }

    if (attachments.isNotEmpty) {
      onAttach(attachments);
    }

    if (skipped.isNotEmpty) {
      return CommandMessage(
        'Skipped ${skipped.length} file(s) (too large): ${skipped.join(', ')}',
        isError: true,
      );
    }

    if (attachments.isEmpty) {
      return const CommandMessage('No files were attached.', isError: true);
    }

    return const CommandDone();
  }
}

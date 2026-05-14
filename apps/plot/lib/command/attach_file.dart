import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/util/image_utils.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/store/store.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/network_exception.dart';
import 'logging.dart';

const _maxFileSize = 25 * 1024 * 1024; // 25MB

/// Uploads a single [PlatformFile] and returns the resulting [FileUserAction].
///
/// Returns `null` if the file bytes/path could not be read.
Future<FileUserAction> _uploadFile({
  required PlatformFile file,
  required String priorityId,
}) async {
  final Map<String, dynamic> response;

  if (kIsWeb) {
    final bytes = file.bytes;
    if (bytes == null) throw StateError('Could not read file bytes.');
    response = await api.uploadFile(
      filePath: '',
      fileName: file.name,
      priorityId: priorityId,
      bytes: bytes,
    );
  } else {
    final path = file.path;
    if (path == null) throw StateError('Could not read file path.');
    response = await api.uploadFile(
      filePath: path,
      fileName: file.name,
      priorityId: priorityId,
    );
  }

  final mimeType = response['mimeType'] as String;
  int? imageWidth;
  int? imageHeight;
  if (mimeType.startsWith('image/')) {
    Uint8List? imageBytes;
    if (kIsWeb) {
      imageBytes = file.bytes;
    } else if (file.path != null) {
      imageBytes = await File(file.path!).readAsBytes();
    }
    if (imageBytes != null) {
      final dims = await getImageDimensions(imageBytes);
      if (dims != null) {
        imageWidth = dims.$1;
        imageHeight = dims.$2;
      }
    }
  }

  return FileUserAction(
    fileId: response['fileId'] as String,
    fileName: response['fileName'] as String,
    fileSize: response['fileSize'] as int,
    mimeType: mimeType,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );
}

class AttachFile extends Command {
  AttachFile({
    required this.priorityId,
    required this.currentLinks,
    required this.onLinksChanged,
  }) : super(
          title: 'Attach file',
          eventObject: EventObject.note,
          eventAction: EventAction.added,
          icon: PlotIcon.attachment,
        );

  final String priorityId;
  final List<UserAction> currentLinks;
  final void Function(List<UserAction> links) onLinksChanged;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) {
      return const CommandSkipped();
    }

    final skipped = <String>[];
    final newFileLinks = <FileUserAction>[];

    for (final file in result.files) {
      if (file.size > _maxFileSize) {
        skipped.add(file.name);
        continue;
      }

      try {
        final fileLink = await _uploadFile(
          file: file,
          priorityId: priorityId,
        );
        newFileLinks.add(fileLink);
      } on NetworkException {
        return CommandMessage(
          "You're offline. Please try again when connected."
              '${newFileLinks.isNotEmpty ? ' ${newFileLinks.length} file(s) were uploaded before the error.' : ''}',
          isError: true,
        );
      } catch (e, t) {
        log.warning('Failed to upload file: ${file.name}', e, t);
        skipped.add(file.name);
      }
    }

    if (newFileLinks.isNotEmpty) {
      onLinksChanged([...currentLinks, ...newFileLinks]);
    }

    if (skipped.isNotEmpty) {
      return CommandMessage(
        'Skipped ${skipped.length} file(s) (too large or failed): ${skipped.join(', ')}',
        isError: true,
      );
    }

    if (newFileLinks.isEmpty) {
      return const CommandMessage(
        'No files were uploaded.',
        isError: true,
      );
    }

    return const CommandDone();
  }
}

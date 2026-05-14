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

  bool get hasFileAttachments =>
      currentLinks.whereType<FileUserAction>().isNotEmpty;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (hasFileAttachments) {
      await Modal(
        constraints: const BoxConstraints(maxHeight: 400, maxWidth: 400),
        builder: (context) => _AttachmentsModal(
          priorityId: priorityId,
          initialLinks: List.of(currentLinks),
          onLinksChanged: onLinksChanged,
        ),
      ).show<void>(context);
      return const CommandDone();
    }

    return _pickAndUpload(currentLinks);
  }

  Future<CommandReturn> _pickAndUpload(List<UserAction> links) async {
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
      onLinksChanged([...links, ...newFileLinks]);
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

class _AttachmentsModal extends StatefulWidget {
  const _AttachmentsModal({
    required this.priorityId,
    required this.initialLinks,
    required this.onLinksChanged,
  });

  final String priorityId;
  final List<UserAction> initialLinks;
  final void Function(List<UserAction> links) onLinksChanged;

  @override
  State<_AttachmentsModal> createState() => _AttachmentsModalState();
}

class _AttachmentsModalState extends State<_AttachmentsModal> {
  late List<UserAction> _links;
  (int current, int total)? _uploadProgress;

  bool get _isUploading => _uploadProgress != null;

  List<FileUserAction> get _fileLinks =>
      _links.whereType<FileUserAction>().toList();

  @override
  void initState() {
    super.initState();
    _links = List.of(widget.initialLinks);
  }

  void _removeFile(FileUserAction fileLink) {
    setState(() {
      _links.removeWhere(
          (l) => l is FileUserAction && l.fileId == fileLink.fileId);
    });
    widget.onLinksChanged(_links);
  }

  Future<void> _addFile() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    final validFiles = <PlatformFile>[];
    final skipped = <String>[];

    for (final file in result.files) {
      if (file.size > _maxFileSize) {
        skipped.add(file.name);
      } else {
        validFiles.add(file);
      }
    }

    if (skipped.isNotEmpty && mounted) {
      context.showToast(
        message:
            'Skipped ${skipped.length} file(s) over 25 MB: ${skipped.join(', ')}',
        isError: true,
      );
    }

    if (validFiles.isEmpty) return;

    setState(() => _uploadProgress = (1, validFiles.length));

    for (var i = 0; i < validFiles.length; i++) {
      final file = validFiles[i];
      if (mounted) {
        setState(() => _uploadProgress = (i + 1, validFiles.length));
      }

      try {
        final fileLink = await _uploadFile(
          file: file,
          priorityId: widget.priorityId,
        );
        if (mounted) {
          setState(() => _links.add(fileLink));
          widget.onLinksChanged(_links);
        }
      } on NetworkException {
        if (mounted) {
          context.showToast(
            message: "You're offline. Please try again when connected.",
            isError: true,
          );
        }
        break;
      } catch (e, t) {
        log.warning('Failed to upload file: ${file.name}', e, t);
        if (mounted) {
          context.showToast(
            message: 'Failed to upload ${file.name}.',
            isError: true,
          );
        }
      }
    }

    if (mounted) {
      setState(() => _uploadProgress = null);
    }
  }

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get _uploadButtonText {
    final progress = _uploadProgress;
    if (progress == null) return 'Add more';
    if (progress.$2 == 1) return 'Uploading...';
    return 'Uploading ${progress.$1} of ${progress.$2}...';
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final fileLinks = _fileLinks;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Attachments', style: theme.typography.lg),
        const SizedBox(height: 12),
        for (final fileLink in fileLinks)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(PlotIcon.attachment, size: 14,
                    color: theme.colors.foreground),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${fileLink.fileName} (${_formatFileSize(fileLink.fileSize)})',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: theme.typography.sm,
                  ),
                ),
                FButton.icon(
                  variant: FButtonVariant.ghost,
                  onPress: () => _removeFile(fileLink),
                  child: Icon(PlotIcon.close, size: 14,
                      color: theme.colors.mutedForeground),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Row(
          children: [
            FButton(
              variant: FButtonVariant.secondary,
              onPress: _isUploading ? null : () => _addFile(),
              prefix: _isUploading
                  ? null
                  : Icon(PlotIcon.add, size: 14,
                      color: theme.colors.foreground),
              child: Text(_uploadButtonText),
            ),
            const Spacer(),
            FButton(
              variant: FButtonVariant.secondary,
              onPress: () => Modal.pop(context, const Value<void>(null)),
              child: const Text('Close'),
            ),
          ],
        ),
      ],
    );
  }
}

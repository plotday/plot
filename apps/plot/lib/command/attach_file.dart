import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/store/store.dart';
import 'package:plot/api/api.dart' as api;
import 'logging.dart';

const _maxFileSize = 25 * 1024 * 1024; // 25MB

class AttachFile extends Command {
  AttachFile({
    required this.priorityId,
    required this.currentLinks,
    required this.onLinksChanged,
  }) : super(
          title: 'Attach File',
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
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) {
      return const CommandSkipped();
    }

    final file = result.files.first;
    final fileName = file.name;
    final fileSize = file.size;

    if (fileSize > _maxFileSize) {
      return const CommandMessage(
        'File is too large. Maximum size is 25 MB.',
        isError: true,
      );
    }

    try {
      final Map<String, dynamic> response;

      if (kIsWeb) {
        final bytes = file.bytes;
        if (bytes == null) {
          return const CommandMessage(
            'Could not read file.',
            isError: true,
          );
        }
        response = await api.uploadFile(
          filePath: '',
          fileName: fileName,
          priorityId: priorityId,
          bytes: bytes,
        );
      } else {
        final path = file.path;
        if (path == null) {
          return const CommandMessage(
            'Could not read file.',
            isError: true,
          );
        }
        response = await api.uploadFile(
          filePath: path,
          fileName: fileName,
          priorityId: priorityId,
        );
      }

      final fileLink = FileUserAction(
        fileId: response['fileId'] as String,
        fileName: response['fileName'] as String,
        fileSize: response['fileSize'] as int,
        mimeType: response['mimeType'] as String,
      );

      onLinksChanged([...links, fileLink]);
      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to upload file', e, t);
      return const CommandMessage(
        'Failed to upload file. Please try again.',
        isError: true,
      );
    }
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
  bool _isUploading = false;

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
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;

    if (file.size > _maxFileSize) {
      if (mounted) {
        context.showToast(
          message: 'File is too large. Maximum size is 25 MB.',
          isError: true,
        );
      }
      return;
    }

    setState(() => _isUploading = true);

    try {
      final Map<String, dynamic> response;

      if (kIsWeb) {
        final bytes = file.bytes;
        if (bytes == null) return;
        response = await api.uploadFile(
          filePath: '',
          fileName: file.name,
          priorityId: widget.priorityId,
          bytes: bytes,
        );
      } else {
        final path = file.path;
        if (path == null) return;
        response = await api.uploadFile(
          filePath: path,
          fileName: file.name,
          priorityId: widget.priorityId,
        );
      }

      final fileLink = FileUserAction(
        fileId: response['fileId'] as String,
        fileName: response['fileName'] as String,
        fileSize: response['fileSize'] as int,
        mimeType: response['mimeType'] as String,
      );

      setState(() {
        _links.add(fileLink);
      });
      widget.onLinksChanged(_links);
    } catch (e, t) {
      log.warning('Failed to upload file', e, t);
      if (mounted) {
        context.showToast(
          message: 'Failed to upload file. Please try again.',
          isError: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
                  style: FButtonStyle.ghost(),
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
              style: FButtonStyle.secondary(),
              onPress: _isUploading ? null : () => _addFile(),
              prefix: _isUploading
                  ? null
                  : Icon(PlotIcon.add, size: 14,
                      color: theme.colors.foreground),
              child: Text(_isUploading ? 'Uploading...' : 'Add another'),
            ),
            const Spacer(),
            FButton(
              style: FButtonStyle.secondary(),
              onPress: () => Modal.pop(context, const Value<void>(null)),
              child: const Text('Close'),
            ),
          ],
        ),
      ],
    );
  }
}

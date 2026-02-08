import 'dart:io' show File;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:forui/forui.dart';
import 'package:path_provider/path_provider.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/value.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/spinner.dart';
import 'package:plot/widget/tapable.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/api/api.dart' as api;
import 'logging.dart';

/// Widget that displays a single note link with appropriate styling based on type
class NoteLinkWidget extends StatelessWidget {
  const NoteLinkWidget({
    required this.link,
    required this.note,
    this.onAuthComplete,
    super.key,
  });

  final Link link;
  final Note note;
  final VoidCallback? onAuthComplete;

  @override
  Widget build(BuildContext context) {
    switch (link.type) {
      case LinkType.auth:
        return AuthButton.authorize(
          link: link as AuthLink,
          onAuth: onAuthComplete,
        );
      case LinkType.callback:
        return CallbackLinkButton(link: link as CallbackLink, note: note);
      case LinkType.external:
        return ExternalLinkButton(link: link as ExternalLink);
      case LinkType.conferencing:
        return ConferencingLinkButton(link: link as ConferencingLink);
      case LinkType.file:
        final fileLink = link as FileLink;
        log.info('[FileLink] fileName=${fileLink.fileName} mimeType=${fileLink.mimeType} isImage=${fileLink.isImage}');
        if (fileLink.isImage) {
          return FileImageWidget(link: fileLink);
        }
        return FileLinkButton(link: fileLink);
    }
  }
}

/// A button widget for callback links that makes API calls
class CallbackLinkButton extends StatefulWidget {
  const CallbackLinkButton({required this.link, required this.note, super.key});

  final CallbackLink link;
  final Note note;

  @override
  State<CallbackLinkButton> createState() => _CallbackLinkButtonState();
}

class _CallbackLinkButtonState extends State<CallbackLinkButton> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: FButtonStyle.secondary(),
      mainAxisSize: MainAxisSize.min,
      onPress: _isLoading ? null : () => _handleTap(),
      child: Flexible(
        child: Text(
          widget.link.title,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ),
    );
  }

  Future<void> _handleTap() async {
    if (_isLoading) return;
    _isLoading = true;

    final callbackToken = widget.link.callback;

    // Add twist tag
    final twistActorId = widget.note.authorId;
    final updated = widget.note.setTag(Tag.twist, twistActorId);
    await updated.save();

    try {
      await api.post<Map<String, dynamic>>(
        '/callback/$callbackToken',
        body: widget.link.toJson(),
      );

      log.info('Callback executed successfully for: ${widget.link.title}');
    } catch (e) {
      log.warning('Failed to execute callback for ${widget.link.title}: $e');
      if (mounted) {
        context.showToast(
          message: 'Unable to complete action. Please try again.',
          isError: true,
        );
      }
    } finally {
      _isLoading = false;
      await (await widget.note.refresh())
          .setTag(Tag.twist, twistActorId, false)
          .save();
    }
  }
}

/// A button widget for non-OAuth links (external, hidden, etc.)
class ExternalLinkButton extends StatelessWidget {
  const ExternalLinkButton({required this.link, super.key});

  final ExternalLink link;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: context.theme.buttonStyles.secondary,
      // ignore: unused_result
      // context.theme.buttonStyles.secondary.copyWith(
      //   contentStyle: context.theme.buttonStyles.secondary.contentStyle
      //       // ignore: unused_result
      //       .copyWith(
      //         padding: const EdgeInsets.symmetric(
      //           horizontal: 8,
      //           vertical: 6,
      //         ),
      //       ),
      // ),
      mainAxisSize: MainAxisSize.min,
      onPress: () => _handleTap(),
      child: Flexible(
        child: Text(
          link.title,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ),
    );
  }

  void _handleTap() {
    final url = link.url;
    try {
      final uri = Uri.parse(url);
      launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, t) {
      log.warning('Failed to launch URL: $url', e, t);
    }
  }
}

/// A button widget for conferencing links with provider-specific titles
class ConferencingLinkButton extends StatelessWidget {
  const ConferencingLinkButton({required this.link, super.key});

  final ConferencingLink link;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: FButtonStyle.secondary(),
      mainAxisSize: MainAxisSize.min,
      onPress: () => _handleTap(),
      child: Flexible(
        child: Text(
          _getTitle(),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ),
    );
  }

  String _getTitle() {
    switch (link.provider) {
      case ConferencingProvider.googleMeet:
        return 'Join Google Meet';
      case ConferencingProvider.zoom:
        return 'Join on Zoom';
      case ConferencingProvider.microsoftTeams:
        return 'Join on Teams';
      case ConferencingProvider.webex:
        return 'Join Webex';
      case ConferencingProvider.other:
        return 'Join Meeting';
    }
  }

  void _handleTap() {
    final url = link.url;
    try {
      final uri = Uri.parse(url);
      launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, t) {
      log.warning('Failed to launch URL: $url', e, t);
    }
  }
}

/// A button widget for file attachment links with download support
class FileLinkButton extends StatefulWidget {
  const FileLinkButton({required this.link, super.key});

  final FileLink link;

  @override
  State<FileLinkButton> createState() => _FileLinkButtonState();
}

class _FileLinkButtonState extends State<FileLinkButton> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: FButtonStyle.secondary(),
      mainAxisSize: MainAxisSize.min,
      onPress: _isLoading ? null : () => _handleTap(),
      prefix: _isLoading ? null : Icon(PlotIcon.attachment, size: 14,
          color: context.theme.colors.foreground),
      child: Flexible(
        child: Text(
          '${widget.link.fileName} (${_formatFileSize(widget.link.fileSize)})',
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ),
    );
  }

  Future<void> _handleTap() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final bytes = await api.getFileBytes(widget.link.fileId);

      if (kIsWeb) {
        final blob = Uri.dataFromBytes(bytes, mimeType: widget.link.mimeType);
        await launchUrl(blob);
      } else {
        // Save to temp dir and open with system viewer
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/${widget.link.fileName}');
        await file.writeAsBytes(bytes);
        final uri = Uri.file(file.path);
        await launchUrl(uri);
      }
    } catch (e, t) {
      log.warning('Failed to download file: ${widget.link.fileName}', e, t);
      if (mounted) {
        context.showToast(
          message: 'Failed to download file. Please try again.',
          isError: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Displays an image attachment inline with a max height, opening a
/// zoomable modal on tap. Falls back to [FileLinkButton] on error.
class FileImageWidget extends StatefulWidget {
  const FileImageWidget({required this.link, super.key});

  final FileLink link;

  @override
  State<FileImageWidget> createState() => _FileImageWidgetState();
}

class _FileImageWidgetState extends State<FileImageWidget> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await api.getFileBytes(widget.link.fileId);
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _loading = false;
        });
      }
    } catch (e) {
      log.warning('Failed to load image: ${widget.link.fileName} (mimeType=${widget.link.mimeType})', e);
      if (mounted) {
        setState(() {
          _error = true;
          _loading = false;
        });
      }
    }
  }

  void _openViewer() {
    final bytes = _bytes;
    if (bytes == null) return;
    Modal(
      constraints: const BoxConstraints(maxHeight: 900, maxWidth: 1200),
      maxWidthPercentage: 0.9,
      maxHeightPercentage: 0.9,
      padding: EdgeInsets.zero,
      builder: (context) => _FullImageViewer(
        bytes: bytes,
        fileName: widget.link.fileName,
      ),
    ).show<void>(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return FileLinkButton(link: widget.link);
    }

    if (_loading) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 200, maxWidth: 300),
        child: const Center(child: Spinner()),
      );
    }

    return Tapable(
      onTap: _openViewer,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: Image.memory(
            _bytes!,
            fit: BoxFit.contain,
            errorBuilder: (_, error, ___) {
              log.warning('[FileImage] decode failed for ${widget.link.fileName}: $error');
              return FileLinkButton(link: widget.link);
            },
          ),
        ),
      ),
    );
  }
}

class _FullImageViewer extends StatelessWidget {
  const _FullImageViewer({required this.bytes, required this.fileName});

  final Uint8List bytes;
  final String fileName;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  fileName,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: DefaultTextStyle.of(context).style.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Tapable(
                onTap: () => Modal.pop<void>(context, const Value(null)),
                child: Icon(
                  PlotIcon.close,
                  size: 16,
                  color: context.theme.colors.foreground,
                ),
              ),
            ],
          ),
        ),
        Flexible(
          child: InteractiveViewer(
            maxScale: 5.0,
            minScale: 0.5,
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
        ),
      ],
    );
  }
}

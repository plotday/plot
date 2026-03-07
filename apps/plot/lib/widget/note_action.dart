import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:forui/forui.dart';
import 'package:path_provider/path_provider.dart';

import 'package:plot/router.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/spinner.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/widget/tapable.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/api/api.dart' as api;
import 'logging.dart';

/// Widget that displays a single note action with appropriate styling based on type
class NoteActionWidget extends StatelessWidget {
  const NoteActionWidget({
    required this.link,
    this.note,
    this.onAuthComplete,
    this.style,
    this.textStyle,
    super.key,
  });

  final UserAction link;
  final Note? note;
  final VoidCallback? onAuthComplete;

  /// Optional button style override (e.g. ghost for thread-level actions).
  final FBaseButtonStyle Function(FButtonStyle)? style;

  /// Optional text style override (e.g. sm for compact actions).
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    switch (link.type) {
      case UserActionType.auth:
        return AuthButton.authorize(
          link: link as AuthUserAction,
          onAuth: onAuthComplete,
        );
      case UserActionType.callback:
        if (note == null) {
          return _CallbackActionWithoutNote(
            link: link as CallbackUserAction,
            style: style,
            textStyle: textStyle,
          );
        }
        return CallbackActionButton(
          link: link as CallbackUserAction,
          note: note!,
          style: style,
          textStyle: textStyle,
        );
      case UserActionType.external:
        return ExternalLinkButton(
          link: link as ExternalUserAction,
          style: style,
          textStyle: textStyle,
        );
      case UserActionType.conferencing:
        return ConferencingLinkButton(
          link: link as ConferencingUserAction,
          style: style,
          textStyle: textStyle,
        );
      case UserActionType.file:
        final fileLink = link as FileUserAction;
        if (fileLink.isImage) {
          return FileImageWidget(link: fileLink);
        }
        return FileLinkButton(
          link: fileLink,
          style: style,
          textStyle: textStyle,
        );
      case UserActionType.thread:
        return ThreadLinkButton(
          link: link as ThreadUserAction,
          style: style,
          textStyle: textStyle,
        );
    }
  }
}

/// A button widget for callback actions that makes API calls
class CallbackActionButton extends StatefulWidget {
  const CallbackActionButton({
    required this.link,
    required this.note,
    this.style,
    this.textStyle,
    super.key,
  });

  final CallbackUserAction link;
  final Note note;
  final FBaseButtonStyle Function(FButtonStyle)? style;
  final TextStyle? textStyle;

  @override
  State<CallbackActionButton> createState() => _CallbackActionButtonState();
}

class _CallbackActionButtonState extends State<CallbackActionButton> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: widget.style ?? FButtonStyle.secondary(),
      mainAxisSize: MainAxisSize.min,
      onPress: _isLoading ? null : () => _handleTap(),
      child: Flexible(
        child: Text(
          widget.link.title,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: widget.textStyle,
        ),
      ),
    );
  }

  Future<void> _handleTap() async {
    if (_isLoading) return;
    _isLoading = true;

    final callbackToken = widget.link.callback;

    // Add twist tag
    final twistActorId = Base.actorId;
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

/// A button for callback actions at the thread level (no note context for tag toggling)
class _CallbackActionWithoutNote extends StatefulWidget {
  const _CallbackActionWithoutNote({
    required this.link,
    this.style,
    this.textStyle,
  });

  final CallbackUserAction link;
  final FBaseButtonStyle Function(FButtonStyle)? style;
  final TextStyle? textStyle;

  @override
  State<_CallbackActionWithoutNote> createState() =>
      _CallbackActionWithoutNoteState();
}

class _CallbackActionWithoutNoteState extends State<_CallbackActionWithoutNote> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: widget.style ?? FButtonStyle.secondary(),
      mainAxisSize: MainAxisSize.min,
      onPress: _isLoading ? null : () => _handleTap(),
      child: Flexible(
        child: Text(
          widget.link.title,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: widget.textStyle,
        ),
      ),
    );
  }

  Future<void> _handleTap() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      await api.post<Map<String, dynamic>>(
        '/callback/${widget.link.callback}',
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
      if (mounted) setState(() => _isLoading = false);
    }
  }
}

/// A button widget for non-OAuth links (external, hidden, etc.)
class ExternalLinkButton extends StatelessWidget {
  const ExternalLinkButton({
    required this.link,
    this.style,
    this.textStyle,
    super.key,
  });

  final ExternalUserAction link;
  final FBaseButtonStyle Function(FButtonStyle)? style;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: style ?? FButtonStyle.secondary(),
      mainAxisSize: MainAxisSize.min,
      onPress: () => _handleTap(),
      child: Flexible(
        child: Text(
          link.title,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: textStyle,
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
  const ConferencingLinkButton({
    required this.link,
    this.style,
    this.textStyle,
    super.key,
  });

  final ConferencingUserAction link;
  final FBaseButtonStyle Function(FButtonStyle)? style;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: style ?? FButtonStyle.secondary(),
      mainAxisSize: MainAxisSize.min,
      onPress: () => _handleTap(),
      child: Flexible(
        child: Text(
          _getTitle(),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: textStyle,
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

/// A button widget for thread reference links that navigate to the referenced thread
class ThreadLinkButton extends StatelessWidget {
  const ThreadLinkButton({
    required this.link,
    this.style,
    this.textStyle,
    super.key,
  });

  final ThreadUserAction link;
  final FBaseButtonStyle Function(FButtonStyle)? style;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: style ?? FButtonStyle.secondary(),
      mainAxisSize: MainAxisSize.min,
      onPress: link.priorityId != null ? () => _handleTap(context) : null,
      child: Flexible(
        child: Text(
          link.title ?? 'Thread',
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: textStyle,
        ),
      ),
    );
  }

  void _handleTap(BuildContext context) {
    final priorityId = link.priorityId;
    if (priorityId == null) return;

    final route = PriorityRoute(
      priorityIdString: Uuid.fromString(priorityId).toShortString(),
      children: [
        ThreadRoute(
          threadIdString: Uuid.fromString(link.threadId).toShortString(),
        ),
      ],
    );
    context.router.root.navigate(route);
  }
}

/// A button widget for file attachment links with download support
class FileLinkButton extends StatefulWidget {
  const FileLinkButton({
    required this.link,
    this.style,
    this.textStyle,
    super.key,
  });

  final FileUserAction link;
  final FBaseButtonStyle Function(FButtonStyle)? style;
  final TextStyle? textStyle;

  @override
  State<FileLinkButton> createState() => _FileLinkButtonState();
}

class _FileLinkButtonState extends State<FileLinkButton> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: widget.style ?? FButtonStyle.secondary(),
      mainAxisSize: MainAxisSize.min,
      onPress: _isLoading ? null : () => _handleTap(),
      prefix: _isLoading
          ? null
          : Icon(
              PlotIcon.attachment,
              size: 14,
              color: context.theme.colors.foreground,
            ),
      child: Flexible(
        child: Text(
          '${widget.link.fileName} (${_formatFileSize(widget.link.fileSize)})',
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: widget.textStyle,
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

  final FileUserAction link;

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
      log.warning(
        'Failed to load image: ${widget.link.fileName} (mimeType=${widget.link.mimeType})',
        e,
      );
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
      builder: (context) =>
          _FullImageViewer(bytes: bytes, fileName: widget.link.fileName),
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
        borderRadius: BorderRadius.circular(borderRadiusMd),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: Image.memory(
            _bytes!,
            fit: BoxFit.contain,
            errorBuilder: (_, error, _) {
              log.warning(
                '[FileImage] decode failed for ${widget.link.fileName}: $error',
              );
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
                  style: DefaultTextStyle.of(
                    context,
                  ).style.copyWith(fontWeight: FontWeight.w600),
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

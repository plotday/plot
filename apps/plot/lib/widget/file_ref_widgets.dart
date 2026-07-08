import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/tapable.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/util/download.dart';
import 'package:plot/util/open_file.dart';
import 'package:plot/analytics/tracker.dart';
import 'logging.dart';

/// A button widget for connector-attached file refs. Downloads the file via the
/// /app/files/ref/:noteId/:actionIndex resolver endpoint.
///
/// On HTTP 410 (source no longer available), shows a toast with an appropriate
/// message. On other errors, shows a generic retry message.
class FileRefLinkButton extends StatefulWidget {
  const FileRefLinkButton({
    required this.link,
    required this.noteId,
    required this.actionIndex,
    this.variant,
    this.style,
    this.textStyle,
    super.key,
  });

  final FileRefUserAction link;
  final String noteId;
  final int actionIndex;
  final FButtonVariant? variant;
  final FButtonStyleDelta? style;
  final TextStyle? textStyle;

  @override
  State<FileRefLinkButton> createState() => _FileRefLinkButtonState();
}

class _FileRefLinkButtonState extends State<FileRefLinkButton> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return FButton(
      variant: widget.variant ?? FButtonVariant.secondary,
      style: widget.style ?? const FButtonStyleDelta.context(),
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
          _label,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: widget.textStyle,
        ),
      ),
    );
  }

  String get _label {
    final size = widget.link.fileSize;
    if (size == null) return widget.link.fileName;
    return '${widget.link.fileName} (${_formatFileSize(size)})';
  }

  Future<void> _handleTap() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final bytes = await api.getFileRefBytes(widget.noteId, widget.actionIndex);
      await openFileBytes(
        bytes: bytes,
        fileName: widget.link.fileName,
        mimeType: widget.link.mimeType,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 410) {
        if (mounted) {
          context.showToast(
            message: 'Source no longer available.',
            isError: true,
          );
        }
      } else {
        log.warning('Failed to download file ref: ${widget.link.fileName}', e);
        if (mounted) {
          context.showToast(
            message: 'Failed to download file. Please try again.',
            isError: true,
          );
        }
      }
    } on NetworkException {
      if (mounted) {
        context.showToast(
          message: "You're offline. Please try again when connected.",
          isError: true,
        );
      }
    } catch (e, t) {
      log.warning('Failed to download file ref: ${widget.link.fileName}', e, t);
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

/// Displays a connector-attached image inline with a max height, opening a
/// zoomable modal on tap. Falls back gracefully on error.
///
/// On HTTP 410, renders a compact "Source no longer available" tile.
class FileRefImageWidget extends StatefulWidget {
  const FileRefImageWidget({
    required this.link,
    required this.noteId,
    required this.actionIndex,
    super.key,
  });

  final FileRefUserAction link;
  final String noteId;
  final int actionIndex;

  @override
  State<FileRefImageWidget> createState() => _FileRefImageWidgetState();
}

class _FileRefImageWidgetState extends State<FileRefImageWidget> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _error = false;
  bool _gone = false; // HTTP 410 — source no longer available

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await api.getFileRefBytes(widget.noteId, widget.actionIndex);
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _loading = false;
        });
      }
    } on ApiException catch (e) {
      log.warning(
        'Failed to load image ref: ${widget.link.fileName} (status=${e.statusCode})',
        e,
      );
      if (mounted) {
        setState(() {
          _gone = e.statusCode == 410;
          _error = true;
          _loading = false;
        });
      }
    } catch (e) {
      log.warning(
        'Failed to load image ref: ${widget.link.fileName} (mimeType=${widget.link.mimeType})',
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

  Future<void> _openViewer() async {
    final bytes = _bytes;
    if (bytes == null) return;
    await _showFileRefFullImageViewer(
      context,
      bytes: bytes,
      fileName: widget.link.fileName,
      mimeType: widget.link.mimeType,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      if (_gone) {
        return _GoneAttachmentTile(fileName: widget.link.fileName);
      }
      return FileRefLinkButton(
        link: widget.link,
        noteId: widget.noteId,
        actionIndex: widget.actionIndex,
      );
    }

    final w = widget.link.imageWidth;
    final h = widget.link.imageHeight;
    final hasDimensions = w != null && h != null && w > 0 && h > 0;

    if (hasDimensions) {
      Widget child;
      if (_loading) {
        child = const _FileRefSkeletonBox();
      } else {
        child = Image.memory(
          _bytes!,
          fit: BoxFit.cover,
          frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded || frame != null) return child;
            return const _FileRefSkeletonBox();
          },
          errorBuilder: (_, error, _) {
            log.warning(
              '[FileRefImage] decode failed for ${widget.link.fileName}: $error',
            );
            return FileRefLinkButton(
              link: widget.link,
              noteId: widget.noteId,
              actionIndex: widget.actionIndex,
            );
          },
        );
      }

      final container = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadiusMd),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: AspectRatio(
            aspectRatio: w / h,
            child: child,
          ),
        ),
      );

      if (_loading) return container;
      return Tapable(onTap: _openViewer, child: container);
    }

    // No dimensions — stable-size container for both states.
    final noDimChild = _loading
        ? const _FileRefSkeletonBox()
        : Image.memory(
            _bytes!,
            fit: BoxFit.contain,
            frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) return child;
              return const _FileRefSkeletonBox();
            },
            errorBuilder: (_, error, _) {
              log.warning(
                '[FileRefImage] decode failed for ${widget.link.fileName}: $error',
              );
              return FileRefLinkButton(
                link: widget.link,
                noteId: widget.noteId,
                actionIndex: widget.actionIndex,
              );
            },
          );

    final noDimContainer = ClipRRect(
      borderRadius: BorderRadius.circular(borderRadiusMd),
      child: SizedBox(
        height: 200,
        width: 300,
        child: noDimChild,
      ),
    );

    if (_loading) return noDimContainer;
    return Tapable(onTap: _openViewer, child: noDimContainer);
  }
}

/// Compact read-only tile shown when a connector attachment source is gone (410).
class _GoneAttachmentTile extends StatelessWidget {
  const _GoneAttachmentTile({required this.fileName});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colors.background,
        border: Border.all(color: theme.colors.border, width: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              PlotIcon.attachment,
              size: 14,
              color: theme.colors.mutedForeground,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Source no longer available',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: theme.typography.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Animated shimmer placeholder for image loading states.
class _FileRefSkeletonBox extends StatefulWidget {
  const _FileRefSkeletonBox();

  @override
  State<_FileRefSkeletonBox> createState() => _FileRefSkeletonBoxState();
}

class _FileRefSkeletonBoxState extends State<_FileRefSkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.read<ThemeBloc>().isDarkMode(context);
    final base = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE8E8E8);
    final highlight = isDark ? const Color(0xFF3A3A3A) : const Color(0xFFF5F5F5);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        final start = -0.5 + t * 2.0;
        final end = start + 0.5;

        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadiusMd),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [base, highlight, base],
              stops: [
                start.clamp(0.0, 1.0),
                ((start + end) / 2).clamp(0.0, 1.0),
                end.clamp(0.0, 1.0),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FileRefFullImageViewer extends StatefulWidget {
  const _FileRefFullImageViewer({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;

  @override
  State<_FileRefFullImageViewer> createState() =>
      _FileRefFullImageViewerState();
}

class _FileRefFullImageViewerState extends State<_FileRefFullImageViewer> {
  bool _downloading = false;

  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final result = await downloadFile(
        bytes: widget.bytes,
        fileName: widget.fileName,
        mimeType: widget.mimeType,
      );
      if (!mounted || !result.success) return;
      final dest = result.destinationLabel;
      context.showToast(
        message: dest != null
            ? 'Saved ${widget.fileName} to $dest'
            : 'Downloaded ${widget.fileName}',
      );
    } catch (e, t) {
      log.warning('Failed to download image: ${widget.fileName}', e, t);
      Tracker.captureException(e, t);
      if (mounted) {
        context.showToast(
          message: 'Failed to download image. Please try again.',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = context.theme.colors.foreground;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.fileName,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: DefaultTextStyle.of(
                    context,
                  ).style.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Tapable(
                onTap: _downloading ? null : _download,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    PlotIcon.download,
                    size: 16,
                    color: _downloading ? fg.withValues(alpha: 0.5) : fg,
                  ),
                ),
              ),
              Tapable(
                onTap: () => Modal.pop<void>(context, const Value(null)),
                child: Icon(PlotIcon.close, size: 16, color: fg),
              ),
            ],
          ),
        ),
        Flexible(
          child: InteractiveViewer(
            maxScale: 5.0,
            minScale: 0.5,
            child: Image.memory(widget.bytes, fit: BoxFit.contain),
          ),
        ),
      ],
    );
  }
}

/// Open the full-image viewer modal for a loaded file-ref image.
Future<void> _showFileRefFullImageViewer(
  BuildContext context, {
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final intrinsicWidth = frame.image.width.toDouble();
  final intrinsicHeight = frame.image.height.toDouble();
  frame.image.dispose();
  codec.dispose();

  if (!context.mounted) return;

  final mediaQuery = MediaQuery.of(context);
  final maxWidth = intrinsicWidth.clamp(0.0, mediaQuery.size.width * 0.9);
  final maxHeight = intrinsicHeight.clamp(0.0, mediaQuery.size.height * 0.9);

  await Modal(
    constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: maxWidth),
    maxWidthPercentage: 0.9,
    maxHeightPercentage: 0.9,
    padding: EdgeInsets.zero,
    builder: (context) => _FileRefFullImageViewer(
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
    ),
  ).show<void>(context);
}

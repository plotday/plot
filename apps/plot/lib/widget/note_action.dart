import 'dart:io' show File;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:forui/forui.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/router.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/widget/tapable.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/network_exception.dart';
import 'logging.dart';

/// Widget that displays a single note action with appropriate styling based on type
class NoteActionWidget extends StatelessWidget {
  const NoteActionWidget({
    required this.link,
    this.note,
    this.onAuthComplete,
    this.variant,
    this.style,
    this.textStyle,
    super.key,
  });

  final UserAction link;
  final Note? note;
  final VoidCallback? onAuthComplete;

  /// Optional button variant override (e.g. ghost for thread-level actions).
  final FButtonVariant? variant;

  /// Optional button style delta override.
  final FButtonStyleDelta? style;

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
            variant: variant,
            style: style,
            textStyle: textStyle,
          );
        }
        return CallbackActionButton(
          link: link as CallbackUserAction,
          note: note!,
          variant: variant,
          style: style,
          textStyle: textStyle,
        );
      case UserActionType.external:
        return ExternalLinkButton(
          link: link as ExternalUserAction,
          variant: variant,
          style: style,
          textStyle: textStyle,
        );
      case UserActionType.conferencing:
        return ConferencingLinkButton(
          link: link as ConferencingUserAction,
          variant: variant,
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
          variant: variant,
          style: style,
          textStyle: textStyle,
        );
      case UserActionType.thread:
        return ThreadLinkButton(
          link: link as ThreadUserAction,
          variant: variant,
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
    this.variant,
    this.style,
    this.textStyle,
    super.key,
  });

  final CallbackUserAction link;
  final Note note;
  final FButtonVariant? variant;
  final FButtonStyleDelta? style;
  final TextStyle? textStyle;

  @override
  State<CallbackActionButton> createState() => _CallbackActionButtonState();
}

class _CallbackActionButtonState extends State<CallbackActionButton> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return FButton(
      variant: widget.variant ?? FButtonVariant.secondary,
      style: widget.style ?? const FButtonStyleDelta.context(),
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
    } on NetworkException {
      if (mounted) {
        context.showToast(
          message: "You're offline. Please try again when connected.",
          isError: true,
        );
      }
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
    this.variant,
    this.style,
    this.textStyle,
  });

  final CallbackUserAction link;
  final FButtonVariant? variant;
  final FButtonStyleDelta? style;
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
      variant: widget.variant ?? FButtonVariant.secondary,
      style: widget.style ?? const FButtonStyleDelta.context(),
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
    } on NetworkException {
      if (mounted) {
        context.showToast(
          message: "You're offline. Please try again when connected.",
          isError: true,
        );
      }
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
    this.variant,
    this.style,
    this.textStyle,
    super.key,
  });

  final ExternalUserAction link;
  final FButtonVariant? variant;
  final FButtonStyleDelta? style;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return FButton(
      variant: variant ?? FButtonVariant.secondary,
      style: style ?? const FButtonStyleDelta.context(),
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
    this.variant,
    this.style,
    this.textStyle,
    super.key,
  });

  final ConferencingUserAction link;
  final FButtonVariant? variant;
  final FButtonStyleDelta? style;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return FButton(
      variant: variant ?? FButtonVariant.secondary,
      style: style ?? const FButtonStyleDelta.context(),
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
    this.variant,
    this.style,
    this.textStyle,
    super.key,
  });

  final ThreadUserAction link;
  final FButtonVariant? variant;
  final FButtonStyleDelta? style;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return FButton(
      variant: variant ?? FButtonVariant.secondary,
      style: style ?? const FButtonStyleDelta.context(),
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
    this.variant,
    this.style,
    this.textStyle,
    super.key,
  });

  final FileUserAction link;
  final FButtonVariant? variant;
  final FButtonStyleDelta? style;
  final TextStyle? textStyle;

  @override
  State<FileLinkButton> createState() => _FileLinkButtonState();
}

class _FileLinkButtonState extends State<FileLinkButton> {
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
    } on NetworkException {
      if (mounted) {
        context.showToast(
          message: "You're offline. Please try again when connected.",
          isError: true,
        );
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

  Future<void> _openViewer() async {
    final bytes = _bytes;
    if (bytes == null) return;

    // Decode intrinsic dimensions to cap at 1:1 resolution
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final intrinsicWidth = frame.image.width.toDouble();
    final intrinsicHeight = frame.image.height.toDouble();
    frame.image.dispose();
    codec.dispose();

    if (!mounted) return;

    final mediaQuery = MediaQuery.of(context);
    final maxWidth = intrinsicWidth.clamp(0.0, mediaQuery.size.width * 0.9);
    final maxHeight = intrinsicHeight.clamp(0.0, mediaQuery.size.height * 0.9);

    Modal(
      constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: maxWidth),
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

    final w = widget.link.imageWidth;
    final h = widget.link.imageHeight;
    final hasDimensions = w != null && h != null && w > 0 && h > 0;

    // When dimensions are known, keep a single stable-sized container for both
    // loading and loaded states.  AspectRatio sizes from constraints + ratio,
    // ignoring the child's intrinsic size, so there is no zero-height frame
    // while Image.memory decodes.
    if (hasDimensions) {
      Widget child;
      if (_loading) {
        child = const _SkeletonBox();
      } else {
        child = Image.memory(
          _bytes!,
          fit: BoxFit.cover,
          errorBuilder: (_, error, _) {
            log.warning(
              '[FileImage] decode failed for ${widget.link.fileName}: $error',
            );
            return FileLinkButton(link: widget.link);
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

    // No dimensions (legacy images) — separate loading / loaded trees.
    if (_loading) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadiusMd),
        child: const SizedBox(
          height: 200,
          width: 300,
          child: _SkeletonBox(),
        ),
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

/// Animated shimmer placeholder: a gradient highlight sweeps across a
/// muted rounded rectangle.  Adapts base/highlight colours to light vs dark
/// mode via [ThemeBloc].
class _SkeletonBox extends StatefulWidget {
  const _SkeletonBox();

  @override
  State<_SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<_SkeletonBox>
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
    final base = isDark
        ? const Color(0xFF2A2A2A)
        : const Color(0xFFE8E8E8);
    final highlight = isDark
        ? const Color(0xFF3A3A3A)
        : const Color(0xFFF5F5F5);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // Slide the gradient stop window from left to right.
        final t = _controller.value;
        final start = -0.5 + t * 2.0; // range -0.5 → 1.5
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

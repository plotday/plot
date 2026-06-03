import 'dart:io' show File;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:forui/forui.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/router.dart';
import 'package:plot/widget/file_ref_widgets.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart' show darkenTheme;
import 'package:plot/widget/auth_button.dart';
import 'package:plot/widget/edit_link_modal.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/logo_image.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/widget/tapable.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/util/download.dart';
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
    this.actionIndex,
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

  /// Index of this action in the note's actions list. Required for
  /// [UserActionType.fileRef] to construct the resolver URL.
  final int? actionIndex;

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
          note: note,
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
      case UserActionType.fileRef:
        final fileRefLink = link as FileRefUserAction;
        final noteIdStr = note?.id.toString();
        final idx = actionIndex;
        if (noteIdStr == null || idx == null) {
          // Context not available — render a disabled placeholder.
          return FButton(
            variant: variant ?? FButtonVariant.secondary,
            style: style ?? const FButtonStyleDelta.context(),
            mainAxisSize: MainAxisSize.min,
            onPress: null,
            prefix: Icon(
              PlotIcon.attachment,
              size: 14,
              color: context.theme.colors.mutedForeground,
            ),
            child: Flexible(
              child: Text(
                fileRefLink.fileName,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: textStyle,
              ),
            ),
          );
        }
        if (fileRefLink.isImage) {
          return FileRefImageWidget(
            link: fileRefLink,
            noteId: noteIdStr,
            actionIndex: idx,
          );
        }
        return FileRefLinkButton(
          link: fileRefLink,
          noteId: noteIdStr,
          actionIndex: idx,
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
      case UserActionType.plan:
        return PlanActionWidget(
          plan: link as PlanUserAction,
          note: note,
        );
      case UserActionType.createLink:
        // Rendered inline by NoteEditor's attachment row; invisible elsewhere.
        return const SizedBox.shrink();
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

/// Widget that displays a plan of operations for user approval.
class PlanActionWidget extends StatefulWidget {
  const PlanActionWidget({
    required this.plan,
    this.note,
    super.key,
  });

  final PlanUserAction plan;
  final Note? note;

  @override
  State<PlanActionWidget> createState() => _PlanActionWidgetState();
}

class _PlanActionWidgetState extends State<PlanActionWidget> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.plan.title,
              style: theme.typography.sm
                  .copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            ...widget.plan.operations.map(
              (op) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '\u2022 ',
                      style: theme.typography.sm.copyWith(
                        color: theme.colors.mutedForeground,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        op.description,
                        style: theme.typography.sm.copyWith(
                          color: theme.colors.mutedForeground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FButton(
                  variant: FButtonVariant.primary,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _isLoading ? null : () => _handleResponse(true),
                  child: Text(
                    'Approve',
                    style: theme.typography.sm,
                  ),
                ),
                const SizedBox(width: 8),
                FButton(
                  variant: FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _isLoading ? null : () => _handleResponse(false),
                  child: Text(
                    'Reject',
                    style: theme.typography.sm,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleResponse(bool approved) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    final callbackToken = widget.plan.callback;
    final note = widget.note;
    final twistActorId = Base.actorId;

    if (note != null) {
      final updated = note.setTag(Tag.twist, twistActorId);
      await updated.save();
    }

    try {
      final body = widget.plan.toJson();
      body['approved'] = approved;
      await api.post<Map<String, dynamic>>(
        '/callback/$callbackToken',
        body: body,
      );

      log.info(
        'Plan ${approved ? 'approved' : 'rejected'}: ${widget.plan.title}',
      );
    } on NetworkException {
      if (mounted) {
        context.showToast(
          message: "You're offline. Please try again when connected.",
          isError: true,
        );
      }
    } catch (e, t) {
      log.warning('Failed to ${approved ? 'approve' : 'reject'} plan: $e');
      Tracker.captureException(e, t);
      if (mounted) {
        context.showToast(
          message: 'Unable to complete action. Please try again.',
          isError: true,
        );
      }
    } finally {
      if (note != null) {
        await (await note.refresh())
            .setTag(Tag.twist, twistActorId, false)
            .save();
      }
      if (mounted) setState(() => _isLoading = false);
    }
  }
}

/// Compact row for an external link attached to a note. Mirrors the visual
/// design of the thread-pinned link row (favicon + title + "..." menu).
class ExternalLinkButton extends StatefulWidget {
  const ExternalLinkButton({
    required this.link,
    this.note,
    this.variant,
    this.style,
    this.textStyle,
    super.key,
  });

  final ExternalUserAction link;

  /// The note this link belongs to. Required for Edit / Pin actions. When
  /// null (e.g. preview contexts), the menu falls back to open-only.
  final Note? note;

  /// Kept for source compatibility with the previous button-based API.
  final FButtonVariant? variant;
  final FButtonStyleDelta? style;
  final TextStyle? textStyle;

  @override
  State<ExternalLinkButton> createState() => _ExternalLinkButtonState();
}

class _ExternalLinkButtonState extends State<ExternalLinkButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) {
          final favicon = widget.link.favicon;
          return GestureDetector(
            onTap: _handleTap,
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.theme.colors.background,
                  border: Border.all(
                    color: context.theme.colors.border,
                    width: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      if (favicon != null)
                        LogoImage(
                          url: favicon,
                          size: 14,
                          fallback: const Icon(PlotIcon.link, size: 14),
                        )
                      else
                        const Icon(PlotIcon.link, size: 14),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.link.title,
                          style: context.theme.typography.sm.copyWith(
                            color: _hovered
                                ? context.theme.colors.foreground
                                : context.theme.colors.foreground.withValues(
                                    alpha: 0.7,
                                  ),
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      if (widget.note != null) ...[
                        const SizedBox(width: 8),
                        _NoteLinkMenu(
                          link: widget.link,
                          note: widget.note!,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _handleTap() {
    final url = widget.link.url;
    try {
      final uri = Uri.parse(url);
      launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, t) {
      log.warning('Failed to launch URL: $url', e, t);
    }
  }
}

/// "..." menu for a note-attached link row. Offers Edit and Pin.
class _NoteLinkMenu extends StatefulWidget {
  const _NoteLinkMenu({required this.link, required this.note});

  final ExternalUserAction link;
  final Note note;

  @override
  State<_NoteLinkMenu> createState() => _NoteLinkMenuState();
}

class _NoteLinkMenuState extends State<_NoteLinkMenu> {
  final _controller = OverlayPortalController();

  @override
  Widget build(BuildContext context) {
    final style = context.theme.popoverMenuStyle;

    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: (overlayContext) {
        final buttonBox = this.context.findRenderObject() as RenderBox;
        final overlay =
            Overlay.of(overlayContext).context.findRenderObject() as RenderBox;
        final position = buttonBox.localToGlobal(
          Offset(buttonBox.size.width, buttonBox.size.height),
          ancestor: overlay,
        );

        return Positioned(
          top: position.dy,
          right: overlay.size.width - position.dx,
          child: TapRegion(
            onTapOutside: (_) => _controller.hide(),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: style.maxWidth),
              child: DecoratedBox(
                decoration: style.decoration,
                child: FInheritedItemData(
                  child: FItemGroup.merge(
                    style: style.itemGroupStyle,
                    divider: FItemDivider.full,
                    children: [FItemGroup(children: _buildMenuItems())],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: GestureDetector(
        onTap: () {
          if (_controller.isShowing) {
            _controller.hide();
          } else {
            _controller.show();
          }
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Icon(
              PlotIcon.more,
              size: 14,
              color: context.theme.colors.foreground.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }

  List<FItem> _buildMenuItems() {
    return [
      FItem(
        title: const Text('Edit link'),
        onPress: () {
          _controller.hide();
          _editLink();
        },
      ),
      FItem(
        title: const Text('Pin to thread'),
        onPress: () {
          _controller.hide();
          _pinLink();
        },
      ),
    ];
  }

  Future<void> _editLink() async {
    final result = await EditLinkModal(
      initialTitle: widget.link.title,
      initialUrl: widget.link.url,
    ).run(context);
    if (result == null) return;
    if (result.title == widget.link.title && result.url == widget.link.url) {
      return;
    }
    final updatedAction = ExternalUserAction(
      title: result.title.isEmpty ? result.url : result.title,
      url: result.url,
      favicon: widget.link.favicon,
    );
    final actions = (widget.note.actions ?? const <UserAction>[])
        .map((a) => identical(a, widget.link) || a == widget.link
            ? updatedAction
            : a)
        .toList();
    await widget.note.copyWith(actions: actions).save();
  }

  Future<void> _pinLink() async {
    final threadId = widget.note.threadId;
    final existing = await Link.getForThread(threadId);
    if (existing.any((l) => l.sourceUrl == widget.link.url)) {
      if (mounted) {
        context.showToast(message: 'Link already pinned');
      }
      return;
    }
    final now = DateTime.now();
    final linkRow = LinkRow(
      id: Uuid.generate(),
      createdAt: now,
      updatedAt: now,
      threadId: threadId,
      sourceCreatedAt: now,
      sourceUrl: widget.link.url,
      title: widget.link.title,
      logo: widget.link.favicon,
      revoked: false,
    );
    await Store.get.save(
      Store.get.links,
      linkRow.toCompanion(false),
      LinksBase(),
    );
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
    final cached = FilePreviewCache.get(widget.link.fileId);
    if (cached != null) {
      _bytes = cached;
      _loading = false;
    } else {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await api.getFileBytes(widget.link.fileId);
      if (mounted) {
        FilePreviewCache.put(widget.link.fileId, bytes);
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
    await _showFullImageViewer(
      context,
      bytes: bytes,
      fileName: widget.link.fileName,
      mimeType: widget.link.mimeType,
    );
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
          frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded || frame != null) return child;
            return const _SkeletonBox();
          },
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

    // No dimensions (legacy images) — stable-size container for both states.
    final noDimChild = _loading
        ? const _SkeletonBox()
        : Image.memory(
            _bytes!,
            fit: BoxFit.contain,
            frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) return child;
              return const _SkeletonBox();
            },
            errorBuilder: (_, error, _) {
              log.warning(
                '[FileImage] decode failed for ${widget.link.fileName}: $error',
              );
              return FileLinkButton(link: widget.link);
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

class _FullImageViewer extends StatefulWidget {
  const _FullImageViewer({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;

  @override
  State<_FullImageViewer> createState() => _FullImageViewerState();
}

class _FullImageViewerState extends State<_FullImageViewer> {
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
                    color: _downloading
                        ? fg.withValues(alpha: 0.5)
                        : fg,
                  ),
                ),
              ),
              Tapable(
                onTap: () => Modal.pop<void>(context, const Value(null)),
                child: Icon(
                  PlotIcon.close,
                  size: 16,
                  color: fg,
                ),
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

/// In-memory cache of image bytes keyed by file id. Populated when an image
/// is pasted/attached locally (so the thumbnail and full-image viewer can
/// render immediately without re-downloading the bytes that were just
/// uploaded). Bounded by a simple LRU to avoid unbounded growth.
class FilePreviewCache {
  FilePreviewCache._();

  static const int _maxEntries = 32;
  static final Map<String, Uint8List> _entries = <String, Uint8List>{};

  static void put(String fileId, Uint8List bytes) {
    _entries.remove(fileId);
    _entries[fileId] = bytes;
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  static Uint8List? get(String fileId) {
    final bytes = _entries.remove(fileId);
    if (bytes != null) _entries[fileId] = bytes;
    return bytes;
  }

  /// Re-key bytes from a temporary id (e.g. the optimistic pending id used
  /// while an upload is in flight) to the real id assigned by the server.
  static void rekey(String fromId, String toId) {
    final bytes = _entries.remove(fromId);
    if (bytes != null) put(toId, bytes);
  }

  static void evict(String fileId) {
    _entries.remove(fileId);
  }
}

/// Open the full-image viewer modal for a loaded image. Caps the modal at
/// intrinsic resolution so small images don't get blurrily upscaled.
Future<void> _showFullImageViewer(
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
    builder: (context) => _FullImageViewer(
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
    ),
  ).show<void>(context);
}

/// A compact square thumbnail of an image attachment. Tapping it opens the
/// same zoomable modal as [FileImageWidget]. Designed for use in tight rows
/// (e.g. attachment lists in the note editor) where a full inline preview
/// would be too large.
class FileImageThumbnail extends StatefulWidget {
  const FileImageThumbnail({
    required this.link,
    this.size = 32,
    super.key,
  });

  final FileUserAction link;
  final double size;

  @override
  State<FileImageThumbnail> createState() => _FileImageThumbnailState();
}

class _FileImageThumbnailState extends State<FileImageThumbnail> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    final cached = FilePreviewCache.get(widget.link.fileId);
    if (cached != null) {
      _bytes = cached;
      _loading = false;
    } else {
      _loadImage();
    }
  }

  @override
  void didUpdateWidget(FileImageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link.fileId == widget.link.fileId) return;
    final cached = FilePreviewCache.get(widget.link.fileId);
    if (cached != null) {
      setState(() {
        _bytes = cached;
        _loading = false;
        _error = false;
      });
    } else {
      setState(() {
        _bytes = null;
        _loading = true;
        _error = false;
      });
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await api.getFileBytes(widget.link.fileId);
      if (mounted) {
        FilePreviewCache.put(widget.link.fileId, bytes);
        setState(() {
          _bytes = bytes;
          _loading = false;
        });
      }
    } catch (e) {
      log.warning(
        'Failed to load thumbnail: ${widget.link.fileName} (mimeType=${widget.link.mimeType})',
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
    await _showFullImageViewer(
      context,
      bytes: bytes,
      fileName: widget.link.fileName,
      mimeType: widget.link.mimeType,
    );
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadiusSm);

    if (_loading) {
      return ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: const _SkeletonBox(),
        ),
      );
    }

    if (_error || _bytes == null) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: Icon(
          PlotIcon.attachment,
          size: 14,
          color: context.theme.colors.mutedForeground,
        ),
      );
    }

    return Tapable(
      onTap: _openViewer,
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Image.memory(
            _bytes!,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Icon(
              PlotIcon.attachment,
              size: 14,
              color: context.theme.colors.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}

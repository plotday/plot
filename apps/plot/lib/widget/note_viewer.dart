import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/note_viewer.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/avatar.dart';
import 'package:plot/widget/editor.dart';
import 'package:plot/widget/icon.dart';

/// Maximum content width in the reading view. Keeps line lengths in a
/// comfortable reading range regardless of how wide the overlay is.
const double _readingMaxWidth = 720.0;

/// Reading-mode viewer for a single [Note]. Renders the full content
/// scrollable and centred, with a floating header showing the author + when
/// the note was created and an X to close.
///
/// Positioning (covers thread panel in multi-panel, full-screen otherwise) is
/// handled by the parent overlay in [ResizablePanelLayout].
class NoteViewer extends StatelessWidget {
  const NoteViewer({required this.note, super.key});

  final Note note;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.colour.background,
      child: Stack(
        children: [
          Positioned.fill(child: _ReadingArea(note: note)),
          _FloatingHeader(note: note),
        ],
      ),
    );
  }
}

class _ReadingArea extends StatelessWidget {
  const _ReadingArea({required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    final content = note.content ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 84, bottom: 64, left: 24, right: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _readingMaxWidth),
          child: content.isEmpty
              ? Text(
                  'Empty note',
                  style: context.theme.typography.md.copyWith(
                    color: context.colour.muted,
                  ),
                )
              : Viewer(markdown: content),
        ),
      ),
    );
  }
}

class _FloatingHeader extends StatelessWidget {
  const _FloatingHeader({required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    // Sit the header in a centred row so it tracks the reading column width
    // — author info on the left, X on the right. The X is also pinned to the
    // absolute top-right of the viewer (regardless of reading column width)
    // so it stays easy to reach on wide screens.
    final bg = context.colour.background;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Stack(
        children: [
          // Soft fade at the top so content scrolling under the header
          // doesn't look harsh against it.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 56,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [bg, bg.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 12, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: _readingMaxWidth,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _AuthorMeta(note: note),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const _CloseButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthorMeta extends StatelessWidget {
  const _AuthorMeta({required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    final mutedSm = context.theme.typography.sm.copyWith(
      color: context.colour.muted,
    );
    final created = note.sourceCreatedAt.toLocal();
    return FutureBuilder<Actor?>(
      future: note.getAuthor(),
      builder: (context, snapshot) {
        final actor = snapshot.data;
        final authorName = actor == null
            ? null
            : (note.authorId.isCurrentUser ? 'You' : actor.nameOrEmail);
        final timeWidget = FTooltip(
          tipBuilder: (context, controller) => Text(
            created.format('MMM d, yyyy, h:mm a'),
          ),
          child: Text(note.sourceCreatedAt.toTimeAgo(), style: mutedSm),
        );
        if (authorName == null || authorName.isEmpty) {
          return timeWidget;
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (actor != null) ...[
              Avatar(actor: actor, tooltip: false),
              const SizedBox(width: 8),
            ],
            Text(authorName, style: mutedSm),
            const SizedBox(width: 6),
            Text('•', style: mutedSm),
            const SizedBox(width: 6),
            timeWidget,
          ],
        );
      },
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) {
    return FButton.icon(
      variant: FButtonVariant.ghost,
      onPress: () => context.read<NoteViewerBloc>().dismiss(),
      child: Icon(
        PlotIcon.close,
        size: context.theme.iconSizes.sm,
        color: context.theme.colors.mutedForeground,
      ),
    );
  }
}

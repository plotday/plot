import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/button.dart';
import 'package:plot/widget/editor.dart';

/// Maximum content width in the reading view. Keeps line lengths in a
/// comfortable reading range regardless of how wide the panel is.
const double _readingMaxWidth = 720.0;

/// Horizontal padding inside the header band. Matches the `FButton.icon`
/// ghost padding on the right so the left-aligned author info sits at the
/// same inset as the X close button.
const double _headerPadH = 12.0;

/// Reading-mode viewer for a single [Note]. Renders the full content
/// scrollable and centred. A header band — styled like ThreadPage's
/// sub-header rows — sits above the reading area with the author + when
/// the note was created on the left and an X to close on the right.
class NoteViewer extends StatelessWidget {
  const NoteViewer({required this.note, super.key});

  final Note note;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.colour.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ViewerHeader(note: note),
          Expanded(child: _ReadingArea(note: note)),
        ],
      ),
    );
  }
}

class _ViewerHeader extends StatelessWidget {
  const _ViewerHeader({required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colour.headerBackground,
        border: Border(
          bottom: BorderSide(
            color: context.theme.colors.border,
            width: 1,
          ),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: _headerPadH,
          vertical: context.theme.spacing.xs,
        ),
        child: Row(
          children: [
            Expanded(child: _AuthorMeta(note: note)),
            const SizedBox(width: 8),
            const _CloseButton(),
          ],
        ),
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
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 64),
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
          tipBuilder: (context, controller) =>
              Text(created.format('MMM d, yyyy, h:mm a')),
          child: Text(note.sourceCreatedAt.toTimeAgo(), style: mutedSm),
        );
        if (authorName == null || authorName.isEmpty) {
          return Align(alignment: Alignment.centerLeft, child: timeWidget);
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                authorName,
                style: mutedSm,
                overflow: TextOverflow.ellipsis,
              ),
            ),
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
  Widget build(BuildContext context) => Button.icon(CloseNoteViewer());
}

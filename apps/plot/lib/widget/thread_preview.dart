import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';

/// A lightweight, read-only render of a neighbor thread for the swipe
/// carousel. Built entirely from the in-memory [Thread] (title + preview
/// snippet) — it creates no [ThreadBloc], no note subscriptions, and no
/// editor, so it never marks the thread read or claims keyboard focus. The
/// full thread view mounts only when the swipe settles and the thread is
/// promoted to the carousel center.
class ThreadPreview extends StatelessWidget {
  const ThreadPreview({required this.thread, super.key});

  final Thread thread;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final spacing = theme.spacing;
    final title = thread.title?.trim();
    final preview = thread.displayPreview?.trim();

    return IgnorePointer(
      child: Container(
        color: theme.colors.background,
        padding: EdgeInsets.all(spacing.lg),
        alignment: Alignment.topLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null && title.isNotEmpty)
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.lg,
              ),
            if (preview != null && preview.isNotEmpty) ...[
              SizedBox(height: spacing.sm),
              Text(
                preview,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Small pill badge shown above a note body when the note's audience
/// diverges from the thread superset. See
/// docs/superpowers/specs/2026-05-27-thread-sharing-models-design.md.
///
/// Text is composed by [Thread.noteBadgeLabel] in the caller; this widget is
/// purely presentational so it can be unit-checked visually.
class NoteBadge extends StatelessWidget {
  const NoteBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: context.theme.colors.secondary.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: context.theme.typography.xs.copyWith(
          color: context.theme.colors.mutedForeground,
        ),
      ),
    );
  }
}

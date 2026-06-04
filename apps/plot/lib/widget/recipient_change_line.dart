import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Interstitial "feed update" line shown between two consecutive notes in a
/// message-sharing thread when the recipient set changed (e.g. "Added Jamie",
/// "Dropped everyone except Paul"). Styled as a feed event: right-aligned,
/// author-name text size, muted, with equal vertical spacing above and below
/// so it reads as an event between the notes rather than a badge on one.
class RecipientChangeLine extends StatelessWidget {
  const RecipientChangeLine({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          label,
          textAlign: TextAlign.right,
          style: context.theme.typography.sm.copyWith(
            color: context.theme.colors.mutedForeground,
          ),
        ),
      ),
    );
  }
}

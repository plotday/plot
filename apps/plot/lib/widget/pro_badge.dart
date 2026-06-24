import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Badge identifying a connector as an "Add-on" connection (has a real
/// per-connection cost — Unipile-backed integrations like LinkedIn, Instagram,
/// WhatsApp). Enabling one needs a purchased $5/mo add-on and counts as a
/// regular connection.
class ProBadge extends StatelessWidget {
  /// Optional explicit accent for the badge. Callers rendering on a surface
  /// that isn't driven by the ambient forui theme (e.g. the onboarding tiles,
  /// which hardcode a white tile on a themed backdrop) must pass this — the
  /// default `theme.colors.primary` is the neutral-theme accent there and the
  /// "Add-on" text would be near-invisible on white. Defaults to the ambient
  /// theme primary for in-app lists.
  const ProBadge({this.color, super.key});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final accent = color ?? theme.colors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'Add-on',
        style: TextStyle(
          fontSize: theme.typography.xs.fontSize,
          color: accent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

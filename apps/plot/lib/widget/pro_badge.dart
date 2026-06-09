import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Badge identifying a connector as "Pro" (has a real per-connection cost —
/// currently Unipile-backed integrations like LinkedIn). Drives plan-specific
/// metering separately from the regular connection pool.
class ProBadge extends StatelessWidget {
  const ProBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'Pro',
        style: TextStyle(
          fontSize: theme.typography.xs.fontSize,
          color: theme.colors.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

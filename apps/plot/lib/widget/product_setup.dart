import 'package:plot/api/twist_api.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/auth_button.dart' show AuthButton;
import 'package:plot/widget/widget.dart';

/// Pre-auth informational product setup screen for composite connections.
///
/// Shows a short header, one informational row per [ProductInfo] (icon + label
/// + description, NO toggles), then a single "Continue with Google" button that
/// requests the union of all product scope groups. Choice happens on Google's
/// consent screen (spec §1.2) — not here.
///
/// Gate this widget behind [TwistIntegrations.isComposite]; the existing
/// [_AuthWithScopeToggles] flow is used for all non-composite connections.
class ProductSetupWidget extends StatelessWidget {
  const ProductSetupWidget({
    super.key,
    required this.provider,
    required this.products,
    required this.twistInstanceId,
    required this.onSuccess,
  });

  final TwistProvider provider;
  final List<ProductInfo> products;
  final String twistInstanceId;
  final Future<void> Function() onSuccess;

  @override
  Widget build(BuildContext context) {
    final spacing = context.theme.spacing;
    final typography = context.theme.typography;
    final colors = context.theme.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Plot can sync these from your Google account. '
          'You choose what to allow on Google\'s next screen.',
          style: typography.sm.copyWith(color: colors.mutedForeground),
        ),
        SizedBox(height: spacing.md),
        for (final product in products) ...[
          _ProductRow(product: product),
          SizedBox(height: spacing.sm),
        ],
        Padding(
          padding: EdgeInsets.only(top: spacing.md),
          child: SizedBox(
            width: double.infinity,
            child: AuthButton.connect(
              provider: provider.provider,
              scopes: provider.scopes,
              twistInstanceId: twistInstanceId,
              enabledScopeGroups:
                  products.map((p) => p.scopeGroupId).toList(),
              onSuccess: onSuccess,
            ),
          ),
        ),
      ],
    );
  }
}

/// A single informational row showing a product's icon, label, and description.
///
/// Purely informational — no toggle or interaction. Desktop cursor convention:
/// no pointer override (arrow cursor, the project-wide default for rows).
class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.product});

  final ProductInfo product;

  @override
  Widget build(BuildContext context) {
    final typography = context.theme.typography;
    final colors = context.theme.colors;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (product.icon.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: LogoImage(
              url: product.icon,
              size: 20,
              fallback: SizedBox(width: 20, height: 20),
            ),
          )
        else
          SizedBox(width: 30),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(product.label, style: typography.md),
              if (product.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    product.description,
                    style: typography.sm.copyWith(
                      color: colors.mutedForeground,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

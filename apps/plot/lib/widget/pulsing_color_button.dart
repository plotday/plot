import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/pulsing_icon.dart';
import 'package:plot/widget/widget.dart';

/// A display-only icon that pulses its color between muted and primary colors.
/// Used for twist tag icons to indicate active processing.
/// Not interactive — twist tags can only be added/removed by twists.
class PulsingColorButton extends StatelessWidget {
  const PulsingColorButton({
    required this.primaryColor,
    super.key,
  });

  final Color primaryColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: PulsingIcon(
        icon: Tag.twist.icon,
        size: context.theme.iconSizes.base,
        primaryColor: primaryColor,
      ),
    );
  }
}

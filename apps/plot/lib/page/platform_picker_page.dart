import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/router.dart';

@RoutePage()
class PlatformPickerPage extends StatelessWidget {
  const PlatformPickerPage({super.key});

  @override
  Widget build(BuildContext context) {
    // This page should only be shown on web
    if (!kIsWeb) {
      // If somehow accessed on native platforms, skip to home
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.router.replaceAll([const PrioritiesRoute()]);
      });
      return const SizedBox.shrink();
    }

    return Scaffold(
      center: true,
      body: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            spacing: 24,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Plot logo
              Center(
                child: SvgPicture.asset(
                  "assets/p.svg",
                  width: 100,
                  height: 100,
                ),
              ),

              // Title and description
              Text(
                'Plot – Traction on Your Priorities',
                textAlign: TextAlign.center,
                style: context.theme.typography.xl2.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),

              // Divider
              Row(
                children: [
                  Expanded(child: FDivider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Get the app',
                      style: context.theme.typography.sm.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                  Expanded(child: FDivider()),
                ],
              ),

              // Native platform options
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  FTooltip(
                    tipBuilder: (context, controller) =>
                        const Text('Coming soon'),
                    child: _PlatformButton(
                      icon: FontAwesomeIcons.apple,
                      label: 'macOS',
                    ),
                  ),
                  FTooltip(
                    tipBuilder: (context, controller) =>
                        const Text('Coming soon'),
                    child: _PlatformButton(
                      icon: FontAwesomeIcons.windows,
                      label: 'Windows',
                    ),
                  ),
                  FTooltip(
                    tipBuilder: (context, controller) =>
                        const Text('Coming soon'),
                    child: _PlatformButton(
                      icon: FontAwesomeIcons.apple,
                      label: 'iOS',
                    ),
                  ),
                  FTooltip(
                    tipBuilder: (context, controller) =>
                        const Text('Coming soon'),
                    child: _PlatformButton(
                      icon: FontAwesomeIcons.googlePlay,
                      label: 'Android',
                    ),
                  ),
                ],
              ),

              // Divider
              Row(
                children: [
                  Expanded(child: FDivider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Or use Plot on the web',
                      style: context.theme.typography.sm.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                  Expanded(child: FDivider()),
                ],
              ),

              // Continue in browser
              _PlatformButton(
                icon: FontAwesomeIcons.globe,
                label: 'Continue in this browser',
                onTap: () async {
                  // Save preference
                  await context
                      .read<LocalPreferencesBloc>()
                      .selectWebPlatform();

                  // Navigate to sign-in or app
                  if (context.mounted) {
                    context.router.replaceAll([SignInRoute()]);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlatformButton extends StatelessWidget {
  const _PlatformButton({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return FButton(
      onPress: onTap,
      style: FButtonStyle.secondary(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            FaIcon(icon, size: 20, color: context.theme.colors.foreground),
            Text(label),
          ],
        ),
      ),
    );
  }
}

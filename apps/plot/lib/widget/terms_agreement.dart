import 'package:url_launcher/link.dart' as url_launcher;
import 'package:plot/widget/widget.dart';

/// Terms of Service and Privacy Policy agreement text
class TermsAgreement extends StatelessWidget {
  const TermsAgreement({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle(
      style: context.theme.typography.base.copyWith(
        height: 1.5,
        color: context.theme.colors.mutedForeground,
      ),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(height: 1.5),
          children: [
            const TextSpan(text: 'By signing in, you agree to our\n'),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: HoverableLink(
                text: 'Terms of Service',
                uri: Uri.parse('https://plot.day/terms'),
                target: url_launcher.LinkTarget.blank,
              ),
            ),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Text(' and '),
            ),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: HoverableLink(
                text: 'Privacy Policy',
                uri: Uri.parse('https://plot.day/privacy'),
                target: url_launcher.LinkTarget.blank,
              ),
            ),
            const TextSpan(text: '.'),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

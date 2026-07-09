import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:plot/state/otp_prompt_controller.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/logging.dart';

/// Persistent toast that surfaces an OTP code or a confirm-account link.
///
/// Shown as a declarative [ValueListenableBuilder]-driven overlay in
/// [AppShell]; dismissed via [OtpPromptController.dismiss].
class OtpToast extends StatelessWidget {
  const OtpToast({
    required this.prompt,
    required this.onDismiss,
    super.key,
  });

  final OtpPrompt prompt;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cta = prompt.cta;
    final isOtp =
        cta.kind == CtaKind.otp && cta.code != null && cta.code!.isNotEmpty;

    return FToast(
      title: Text(
        isOtp
            ? '${cta.service} verification code'
            : 'Confirm your ${cta.service} account',
      ),
      description: isOtp ? _OtpBody(code: cta.code!) : null,
      suffix: _ToastActions(
        isOtp: isOtp,
        code: isOtp ? cta.code : null,
        url: isOtp ? null : cta.url,
        onDismiss: onDismiss,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// OTP code display
// ---------------------------------------------------------------------------

class _OtpBody extends StatelessWidget {
  const _OtpBody({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Text(
      code,
      style: context.theme.typography.lg.copyWith(
        color: context.theme.colors.primary,
        fontWeight: FontWeight.w600,
        letterSpacing: 2,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Action row: copy (OTP) or confirm (link) + dismiss
// ---------------------------------------------------------------------------

class _ToastActions extends StatelessWidget {
  const _ToastActions({
    required this.isOtp,
    required this.onDismiss,
    this.code,
    this.url,
  });

  final bool isOtp;
  final String? code;
  final String? url;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isOtp && code != null) _CopyButton(text: code!),
        if (!isOtp && url != null) _ConfirmButton(url: url!),
        const SizedBox(width: 4),
        FButton.icon(
          variant: FButtonVariant.ghost,
          onPress: onDismiss,
          child: Icon(
            PlotIcon.close,
            size: context.theme.iconSizes.sm,
            color: context.theme.colors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Copy button — mirrors _CopyButton in toast.dart
// ---------------------------------------------------------------------------

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return FButton.icon(
      variant: FButtonVariant.ghost,
      onPress: () {
        Clipboard.setData(ClipboardData(text: widget.text));
        setState(() => _copied = true);
      },
      child: Icon(
        _copied ? FontAwesomeIcons.check : FontAwesomeIcons.copy,
        size: context.theme.iconSizes.sm,
        color: context.theme.colors.mutedForeground,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Confirm button — opens external URL
// ---------------------------------------------------------------------------

class _ConfirmButton extends StatelessWidget {
  const _ConfirmButton({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return FButton(
      variant: FButtonVariant.primary,
      onPress: () async {
        final uri = Uri.tryParse(url);
        if (uri == null) return;
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (e, t) {
          log.warning('Failed to launch confirm URL', e, t);
        }
      },
      child: Text('Confirm', style: context.theme.typography.sm),
    );
  }
}

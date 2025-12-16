import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/api/api.dart' as api;
import 'logging.dart';

/// Widget that displays a single note link with appropriate styling based on type
class NoteLinkWidget extends StatelessWidget {
  const NoteLinkWidget({required this.link, this.onAuthComplete, super.key});

  final Link link;
  final VoidCallback? onAuthComplete;

  @override
  Widget build(BuildContext context) {
    switch (link.type) {
      case LinkType.auth:
        return AuthButton.authorize(
          link: link as AuthLink,
          onAuth: onAuthComplete,
        );
      case LinkType.callback:
        return CallbackLinkButton(link: link as CallbackLink);
      case LinkType.external:
        return ExternalLinkButton(link: link as ExternalLink);
      case LinkType.conferencing:
        return ConferencingLinkButton(link: link as ConferencingLink);
    }
  }
}

/// A button widget for callback links that makes API calls
class CallbackLinkButton extends StatefulWidget {
  const CallbackLinkButton({required this.link, super.key});

  final CallbackLink link;

  @override
  State<CallbackLinkButton> createState() => _CallbackLinkButtonState();
}

class _CallbackLinkButtonState extends State<CallbackLinkButton> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: FButtonStyle.secondary(),
      mainAxisSize: MainAxisSize.min,
      onPress: _isLoading ? null : () => _handleTap(),
      suffix: _isLoading
          ? FCircularProgress(
              style:
                  FCircularProgressStyle.inherit(
                    colors: context.theme.colors,
                    // ignore: unused_result
                  ).copyWith(
                    iconStyle: IconThemeData(
                      color: context.theme.colors.foreground,
                      size: 15,
                    ),
                  ),
            )
          : null,
      child: Text(widget.link.title),
    );
  }

  Future<void> _handleTap() async {
    final callbackToken = widget.link.callback;

    setState(() {
      _isLoading = true;
    });

    try {
      await api.post<Map<String, dynamic>>(
        '/callback/$callbackToken',
        body: widget.link.toJson(),
      );

      log.info('Callback executed successfully for: ${widget.link.title}');
    } catch (e) {
      log.warning('Failed to execute callback for ${widget.link.title}: $e');
      // TODO: Show user-friendly error message
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
}

/// A button widget for non-OAuth links (external, hidden, etc.)
class ExternalLinkButton extends StatelessWidget {
  const ExternalLinkButton({required this.link, super.key});

  final ExternalLink link;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: FButtonStyle.secondary(),
      mainAxisSize: MainAxisSize.min,
      onPress: () => _handleTap(),
      child: Text(link.title),
    );
  }

  void _handleTap() {
    final url = link.url;
    try {
      final uri = Uri.parse(url);
      launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, t) {
      log.warning('Failed to launch URL: $url', e, t);
    }
  }
}

/// A button widget for conferencing links with provider-specific titles
class ConferencingLinkButton extends StatelessWidget {
  const ConferencingLinkButton({required this.link, super.key});

  final ConferencingLink link;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: FButtonStyle.secondary(),
      mainAxisSize: MainAxisSize.min,
      onPress: () => _handleTap(),
      child: Text(_getTitle()),
    );
  }

  String _getTitle() {
    switch (link.provider) {
      case ConferencingProvider.googleMeet:
        return 'Join Google Meet';
      case ConferencingProvider.zoom:
        return 'Join on Zoom';
      case ConferencingProvider.microsoftTeams:
        return 'Join on Teams';
      case ConferencingProvider.webex:
        return 'Join Webex';
      case ConferencingProvider.other:
        return 'Join Meeting';
    }
  }

  void _handleTap() {
    final url = link.url;
    try {
      final uri = Uri.parse(url);
      launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, t) {
      log.warning('Failed to launch URL: $url', e, t);
    }
  }
}

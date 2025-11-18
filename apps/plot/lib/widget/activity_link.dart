import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/api/api.dart' as api;
import 'logging.dart';

/// Widget that displays a single activity link with appropriate styling based on type
class ActivityLinkWidget extends StatelessWidget {
  const ActivityLinkWidget({
    required this.link,
    this.onAuthComplete,
    super.key,
  });

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
      style: FButtonStyle.primary(),
      mainAxisSize: MainAxisSize.min,
      onPress: _isLoading ? null : () => _handleTap(),
      child: _isLoading
          ? SizedBox(width: 16, height: 16, child: FCircularProgress())
          : Text(widget.link.title),
    );
  }

  Future<void> _handleTap() async {
    final callbackToken = widget.link.token;

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
    return FButton(onPress: () => _handleTap(), child: Text(link.title));
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
    return FButton(onPress: () => _handleTap(), child: Text(_getTitle()));
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

/// Widget that displays all links for an activity with proper type-based rendering
class ActivityLinksList extends StatelessWidget {
  const ActivityLinksList({
    required this.activity,
    this.onAuthComplete,
    super.key,
  });

  final Activity activity;
  final VoidCallback? onAuthComplete;

  @override
  Widget build(BuildContext context) {
    if (activity.links.isEmpty) {
      return const SizedBox.shrink();
    }

    final widgets = activity.links.map((link) {
      // Use stable, content-based keys instead of hashCode
      final Key key;
      if (link.type == LinkType.auth) {
        final authLink = link as AuthLink;
        key = ValueKey('auth_${authLink.callback}');
        return AuthButton.authorize(
          key: key,
          link: authLink,
          onAuth: onAuthComplete,
        );
      } else if (link.type == LinkType.callback) {
        final callbackLink = link as CallbackLink;
        key = ValueKey('callback_${callbackLink.token}');
        return CallbackLinkButton(key: key, link: callbackLink);
      } else if (link.type == LinkType.conferencing) {
        final conferencingLink = link as ConferencingLink;
        key = ValueKey('conferencing_${conferencingLink.url}');
        return ConferencingLinkButton(key: key, link: conferencingLink);
      } else {
        final externalLink = link as ExternalLink;
        key = ValueKey('external_${externalLink.url}');
        return ExternalLinkButton(key: key, link: externalLink);
      }
    }).toList();

    return Wrap(spacing: 8, runSpacing: 8, children: widgets);
  }
}

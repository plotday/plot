import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/api/api.dart' as api;
import 'logging.dart';

/// Widget that displays a single note link with appropriate styling based on type
class NoteLinkWidget extends StatelessWidget {
  const NoteLinkWidget({
    required this.link,
    required this.note,
    this.onAuthComplete,
    super.key,
  });

  final Link link;
  final Note note;
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
        return CallbackLinkButton(link: link as CallbackLink, note: note);
      case LinkType.external:
        return ExternalLinkButton(link: link as ExternalLink);
      case LinkType.conferencing:
        return ConferencingLinkButton(link: link as ConferencingLink);
    }
  }
}

/// A button widget for callback links that makes API calls
class CallbackLinkButton extends StatefulWidget {
  const CallbackLinkButton({required this.link, required this.note, super.key});

  final CallbackLink link;
  final Note note;

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
      child: Text(widget.link.title),
    );
  }

  Future<void> _handleTap() async {
    setState(() => _isLoading = true);

    final callbackToken = widget.link.callback;

    // Get the twist actor ID from the note's author (only twists add callback buttons)
    final twistActorId =
        widget.note.authorId.isTwist ? widget.note.authorId : null;

    // Add twist tag at start (if the author is a twist)
    if (twistActorId != null) {
      final updated = widget.note.toggleTag(Tag.twist, twistActorId);
      await updated.save();
    }

    try {
      await api.post<Map<String, dynamic>>(
        '/callback/$callbackToken',
        body: widget.link.toJson(),
      );

      log.info('Callback executed successfully for: ${widget.link.title}');
    } catch (e) {
      log.warning('Failed to execute callback for ${widget.link.title}: $e');
      if (mounted) {
        context.showToast(
          message: 'Unable to complete action. Please try again.',
          isError: true,
        );
      }
    } finally {
      // Remove twist tag at end (if we have a twist actor)
      if (twistActorId != null) {
        // Re-fetch the note to get fresh state with the tag
        final freshNote = await Note.get(widget.note.id);
        if (freshNote != null && freshNote.hasTag(Tag.twist, twistActorId)) {
          final updated = freshNote.toggleTag(Tag.twist, twistActorId);
          await updated.save();
        }
      }

      // Always reset local loading state
      if (mounted) {
        setState(() => _isLoading = false);
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
      style: context.theme.buttonStyles.secondary,
      // ignore: unused_result
      // context.theme.buttonStyles.secondary.copyWith(
      //   contentStyle: context.theme.buttonStyles.secondary.contentStyle
      //       // ignore: unused_result
      //       .copyWith(
      //         padding: const EdgeInsets.symmetric(
      //           horizontal: 8,
      //           vertical: 6,
      //         ),
      //       ),
      // ),
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

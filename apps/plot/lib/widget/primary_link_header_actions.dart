import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/hooks.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/status_icon_button.dart';

/// Header actions derived from the thread's primary canonical link: a
/// join-meeting button for each conferencing action, plus the status icon
/// (always shown in the header, even for `hiddenDefault` statuses). Renders
/// nothing when the thread has no canonical link.
class PrimaryLinkHeaderActions extends HookWidget {
  const PrimaryLinkHeaderActions({required this.thread, super.key});

  final Thread thread;

  @override
  Widget build(BuildContext context) {
    final snapshot = useStream<List<Link>>(
      useMemoized(() => Link.watchForThread(thread.id), [thread.id]),
    );
    final links = snapshot.data ?? const <Link>[];
    final primary = Thread.primaryLink(links);
    if (primary == null) return const SizedBox.shrink();

    final conferencing = (primary.actions ?? const <UserAction>[])
        .whereType<ConferencingUserAction>()
        .toList();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final action in conferencing)
          _JoinMeetingButton(action: action),
        StatusIconButton(link: primary, showWhenHiddenDefault: true),
      ],
    );
  }
}

class _JoinMeetingButton extends StatelessWidget {
  const _JoinMeetingButton({required this.action});

  final ConferencingUserAction action;

  @override
  Widget build(BuildContext context) {
    final tooltip = switch (action.provider) {
      ConferencingProvider.googleMeet => 'Join Google Meet',
      ConferencingProvider.zoom => 'Join on Zoom',
      ConferencingProvider.microsoftTeams => 'Join on Teams',
      ConferencingProvider.webex => 'Join Webex',
      ConferencingProvider.other => 'Join Meeting',
    };
    return FTooltip(
      tipBuilder: (tipCtx, controller) => Text(tooltip),
      child: GestureDetector(
        onTap: () async {
          final uri = Uri.tryParse(action.url);
          if (uri == null) return;
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Icon(
            PlotIcon.video,
            size: 14,
            color: context.theme.colors.foreground.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

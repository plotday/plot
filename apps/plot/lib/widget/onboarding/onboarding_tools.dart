import 'dart:async';

import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/api/twist_api.dart';
import 'package:plot/command/twist.dart';
import 'package:plot/command/upgrade.dart' show ShowUpgradeOptions;
import 'package:plot/widget/logo_image.dart';
import 'package:plot/widget/logging.dart';
import 'package:plot/widget/onboarding/onboarding_hoverable.dart';

/// `Twist.category` values that get their own onboarding section. Every other
/// (or null) category falls through to the catch-all "Apps" section. These
/// must match the strings connectors declare in their `package.json` and that
/// the API persists to `twist.category`.
const _messagingCategory = 'messaging';
const _calendarCategory = 'calendar';

/// Renders the content of the "Connect your other tools" onboarding step.
///
/// Lists every source connector available to the user (Gmail, Slack, Linear,
/// GitHub, Drive, calendars, etc.) grouped by category (Messaging / Calendars /
/// Apps) as branded tiles. Tapping a tile opens the standard [AddSourceDetail]
/// modal so the connector's own auth flow / options form runs unchanged.
///
/// Already-connected sources of these types appear above the buttons in the
/// same prominent card style as the calendars step. Tapping a card opens
/// [EditSource] for tweaks or archiving.
class OnboardingTools extends StatefulWidget {
  const OnboardingTools({super.key});

  @override
  State<OnboardingTools> createState() => _OnboardingToolsState();
}

class _OnboardingToolsState extends State<OnboardingTools> {
  List<Twist>? _twists;
  List<SourceSummary> _connected = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        TwistApi.getAllTwists(),
        TwistApi.getSourcesSummary(),
      ]);
      if (!mounted) return;
      setState(() {
        _twists = results[0] as List<Twist>;
        _connected = results[1] as List<SourceSummary>;
        _loading = false;
      });
    } catch (e, t) {
      log.warning('Failed to load onboarding tools', e, t);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openSetup(Twist twist) async {
    await AddSourceDetail(twist, dismissable: true).run(context);
    // Mirror ManageConnections: after OAuth, AddSourceDetail leaves the
    // connection as a DRAFT and hands it off here. We open EditSource so the
    // user picks channels; saving there activates the draft, abandoning
    // deletes it. Without this step the source would stay an unconfirmed draft
    // and never appear as an established connection.
    final connectedDraftId = AddSourceDetail.lastConnectedDraftId;
    final connectedTeamId = AddSourceDetail.lastConnectedTeamId;
    final completedInSetup = AddSourceDetail.lastActivatedInSetupModal;
    AddSourceDetail.lastConnectedDraftId = null;
    AddSourceDetail.lastConnectedTeamId = null;
    AddSourceDetail.lastActivatedInSetupModal = false;
    if (mounted &&
        shouldOpenChannelSetupAfterConnect(
          connectedDraftId: connectedDraftId,
          hasProviders: twist.providers.isNotEmpty,
          completedInSetupModal: completedInSetup,
        )) {
      EditSource.preloadIntegrations(connectedDraftId!);
      if (!mounted) return;
      await EditSource(
        twistInstanceId: connectedDraftId,
        name: twist.name,
        isNewlyActivated: true,
        dismissable: true,
        logoUrl: twist.logoUrl,
        logoUrlDark: twist.logoUrlDark,
        initialTeamHint: connectedTeamId,
      ).run(context);
    }
    if (mounted) await _load();
  }

  Future<void> _editConnection(SourceSummary source) async {
    EditSource.preloadIntegrations(source.id);
    await EditSource(
      twistInstanceId: source.id,
      name: source.twistName ?? source.name,
      dismissable: true,
      logoUrl: source.logoUrl,
      logoUrlDark: source.logoUrlDark,
      accountLabel: source.accountLabel,
    ).run(context);
    if (!mounted) return;
    try {
      final sources = await TwistApi.getSourcesSummary();
      if (!mounted) return;
      setState(() => _connected = sources);
    } catch (e, t) {
      log.warning('Failed to refresh after edit', e, t);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 80,
        child: Center(child: _WhiteSpinner()),
      );
    }

    final twists = _twists ?? const <Twist>[];
    // Dedupe by package_id — the user can have the same connector available
    // across multiple environments (e.g. public + personal/review), and we
    // only want one tile per connector in the onboarding grid. Preserve the
    // first occurrence per package; sort handles the final order.
    final seenPackageIds = <String>{};
    final tools =
        twists
            .where(
              (t) =>
                  t.isSource &&
                  t.twistPackageId != null &&
                  seenPackageIds.add(t.twistPackageId!),
            )
            .toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    // Bucket the available connectors into the three onboarding sections.
    // Anything without a recognized category (including null) falls through
    // to "Apps" so a new or uncategorized connector is never dropped.
    final messaging =
        tools.where((t) => t.category == _messagingCategory).toList();
    final calendars =
        tools.where((t) => t.category == _calendarCategory).toList();
    final apps = tools
        .where(
          (t) =>
              t.category != _messagingCategory &&
              t.category != _calendarCategory,
        )
        .toList();

    // Exclude drafts and partially-set-up sources (OAuth completed but
    // EditSource closed without picking channels). They linger in
    // /sources/summary but aren't real connections from the user's
    // perspective. ManageConnections applies the same rule.
    final connected =
        _connected
            .where((s) => s.twistPackageId != null && s.enabledCount > 0)
            .toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        // Pick a tile width so we get a clean N-up grid: aim for ~180px
        // tiles, with at least 1 per row at narrow widths and as many as fit
        // up to 4 per row on wide screens.
        const minTile = 150.0;
        const idealTile = 180.0;
        const spacing = 10.0;
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 400.0;
        var columns = ((available + spacing) / (idealTile + spacing)).floor();
        if (columns < 1) columns = 1;
        if (columns > 4) columns = 4;
        final tileWidth =
            ((available - spacing * (columns - 1)) / columns).clamp(
              minTile,
              280.0,
            );
        // Activated connections render two-up regardless of the tile grid.
        final connectedTileWidth = (available - spacing) / 2;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (connected.isNotEmpty)
              _ConnectedSection(
                sources: connected,
                tileWidth: connectedTileWidth,
                spacing: spacing,
                onTap: _editConnection,
              ),
            _ToolSection(
              title: 'Messaging',
              twists: messaging,
              tileWidth: tileWidth,
              spacing: spacing,
              onTap: _openSetup,
            ),
            _ToolSection(
              title: 'Calendars',
              twists: calendars,
              tileWidth: tileWidth,
              spacing: spacing,
              onTap: _openSetup,
            ),
            _ToolSection(
              title: 'Apps',
              twists: apps,
              tileWidth: tileWidth,
              spacing: spacing,
              onTap: _openSetup,
            ),
            const SizedBox(height: 20),
            const _UpgradeCopy(),
          ],
        );
      },
    );
  }
}

/// Brand-styled tile for a single connector. Tapping opens AddSourceDetail
/// so the connector's standard auth + options form drives the rest.
class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.twist, required this.onTap});

  final Twist twist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OnboardingHoverable(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: hovered
              ? const Color(0xFFF5F3FF)
              : const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(10),
          boxShadow: hovered
              ? const [
                  BoxShadow(
                    color: Color(0x26000000),
                    blurRadius: 12,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (twist.logoUrl != null) ...[
              LogoImage(url: twist.logoUrl!, size: 20),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(
                twist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF1F1F1F),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A labeled group of connector tiles (e.g. "Messaging"). Renders nothing
/// when [twists] is empty so empty sections disappear.
class _ToolSection extends StatelessWidget {
  const _ToolSection({
    required this.title,
    required this.twists,
    required this.tileWidth,
    required this.spacing,
    required this.onTap,
  });

  final String title;
  final List<Twist> twists;
  final double tileWidth;
  final double spacing;
  final void Function(Twist) onTap;

  @override
  Widget build(BuildContext context) {
    if (twists.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8, left: 2),
            child: Text(
              title,
              style: const TextStyle(
                color: Color(0xFFFFFFFF),
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          Wrap(
            spacing: spacing,
            runSpacing: spacing,
            alignment: WrapAlignment.start,
            children: [
              for (final twist in twists)
                SizedBox(
                  width: tileWidth,
                  child: _ToolTile(twist: twist, onTap: () => onTap(twist)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The user's already-activated connections, shown two-up under a
/// "Your connections" heading. Renders nothing when there are none. Tapping a
/// card opens [EditSource] for tweaks or archiving.
class _ConnectedSection extends StatelessWidget {
  const _ConnectedSection({
    required this.sources,
    required this.tileWidth,
    required this.spacing,
    required this.onTap,
  });

  final List<SourceSummary> sources;
  final double tileWidth;
  final double spacing;
  final void Function(SourceSummary) onTap;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 12, bottom: 8, left: 2),
            child: Text(
              'Your connections',
              style: TextStyle(
                color: Color(0xFFFFFFFF),
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          Wrap(
            spacing: spacing,
            runSpacing: spacing,
            alignment: WrapAlignment.start,
            children: [
              for (final source in sources)
                SizedBox(
                  width: tileWidth,
                  child: _ConnectedRow(
                    source: source,
                    onTap: () => onTap(source),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Plan-limit copy shown beneath the connector sections, with a tappable
/// "Upgrade to Plot Pro" span that opens the standard upgrade flow
/// (StoreKit on App Store builds, web upgrade URL elsewhere — handled by
/// [ShowUpgradeOptions]).
class _UpgradeCopy extends StatefulWidget {
  const _UpgradeCopy();

  @override
  State<_UpgradeCopy> createState() => _UpgradeCopyState();
}

class _UpgradeCopyState extends State<_UpgradeCopy> {
  late final TapGestureRecognizer _recognizer;

  @override
  void initState() {
    super.initState();
    _recognizer = TapGestureRecognizer()..onTap = _onUpgradeTap;
  }

  @override
  void dispose() {
    _recognizer.dispose();
    super.dispose();
  }

  Future<void> _onUpgradeTap() async {
    await ShowUpgradeOptions().run(context);
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: const TextStyle(
          color: Color(0xCCFFFFFF),
          fontSize: 13,
          height: 1.5,
          fontWeight: FontWeight.w400,
          decoration: TextDecoration.none,
        ),
        children: [
          const TextSpan(
            text:
                'Add up to five connections on Plot Core, which you can try '
                'for 30 days. You can always use two connections for free. ',
          ),
          TextSpan(
            text: 'Upgrade to Plot Pro',
            style: const TextStyle(
              color: Color(0xFFFFFFFF),
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
            ),
            recognizer: _recognizer,
          ),
          const TextSpan(text: ' for unlimited connections.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _ConnectedRow extends StatelessWidget {
  const _ConnectedRow({required this.source, required this.onTap});

  final SourceSummary source;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accountLabel = source.accountLabel ?? source.name;
    return OnboardingHoverable(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: hovered
              ? const Color(0xFFF5F3FF)
              : const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: hovered
                  ? const Color(0x33000000)
                  : const Color(0x1A000000),
              blurRadius: hovered ? 16 : 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            if (source.logoUrl != null) ...[
              LogoImage(url: source.logoUrl!, size: 24),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    source.name,
                    style: const TextStyle(
                      color: Color(0xFF1F1F1F),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  if (accountLabel != source.name) ...[
                    const SizedBox(height: 2),
                    Text(
                      accountLabel,
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(
                color: Color(0xFF10B981),
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Icon(
                  FontAwesomeIcons.check,
                  size: 12,
                  color: Color(0xFFFFFFFF),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WhiteSpinner extends StatefulWidget {
  const _WhiteSpinner();

  @override
  State<_WhiteSpinner> createState() => _WhiteSpinnerState();
}

class _WhiteSpinnerState extends State<_WhiteSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0x66FFFFFF), width: 2),
          gradient: const SweepGradient(
            colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF)],
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/api/twist_api.dart';
import 'package:plot/command/twist.dart';
import 'package:plot/widget/logo_image.dart';
import 'package:plot/widget/logging.dart';
import 'package:plot/widget/onboarding/onboarding_hoverable.dart';

/// Calendar connector twist_package_ids excluded from the tools step —
/// those are handled by the dedicated "Connect your calendars" step.
const _calendarPackageIds = <String>{
  '2ed4fcf8-6524-410f-b318-f9316e71c8b0', // Google Calendar
  'cf518010-30c1-4594-b3df-295a19d65459', // Outlook Calendar
  '174bbfb4-97f5-49a7-abde-cb237675dd51', // Apple Calendar
};

/// Renders the content of the "Connect your other tools" onboarding step.
///
/// Lists every source connector available to the user (Gmail, Slack, Linear,
/// GitHub, Drive, etc.) — minus the calendar connectors that have their own
/// step — as branded tiles. Tapping a tile opens the standard [AddSourceDetail]
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
    // Mirror ManageConnections: AddSourceDetail handles OAuth and activates
    // the draft, but it does NOT open EditSource for channel selection.
    // Without that step, the source ends up with enabledCount == 0 and our
    // "established connection" filter (matches ManageConnections) hides it,
    // so the user sees the modal close without a card appearing.
    final activatedId = AddSourceDetail.lastActivatedSourceId;
    AddSourceDetail.lastActivatedSourceId = null;
    if (mounted && activatedId != null && twist.providers.isNotEmpty) {
      EditSource.preloadIntegrations(activatedId);
      if (!mounted) return;
      await EditSource(
        twistInstanceId: activatedId,
        name: twist.name,
        isNewlyActivated: true,
        dismissable: true,
        logoUrl: twist.logoUrl,
        logoUrlDark: twist.logoUrlDark,
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
                  !_calendarPackageIds.contains(t.twistPackageId) &&
                  seenPackageIds.add(t.twistPackageId!),
            )
            .toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final connected =
        _connected
            .where(
              (s) =>
                  s.twistPackageId != null &&
                  !_calendarPackageIds.contains(s.twistPackageId) &&
                  // Exclude drafts and partially-set-up sources (OAuth
                  // completed but EditSource closed without picking
                  // channels). They linger in /sources/summary but aren't
                  // real connections from the user's perspective.
                  // ManageConnections applies the same rule.
                  s.enabledCount > 0,
            )
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

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final source in connected)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ConnectedRow(
                  source: source,
                  onTap: () => _editConnection(source),
                ),
              ),
            if (connected.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Add more or continue below',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xCCFFFFFF),
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
            Wrap(
              spacing: spacing,
              runSpacing: spacing,
              alignment: WrapAlignment.center,
              children: [
                for (final twist in tools)
                  SizedBox(
                    width: tileWidth,
                    child: _ToolTile(
                      twist: twist,
                      onTap: () => _openSetup(twist),
                    ),
                  ),
              ],
            ),
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

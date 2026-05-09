import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/api/twist_api.dart';
import 'package:plot/command/twist.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/widget/logo_image.dart';
import 'package:plot/widget/logging.dart';
import 'package:plot/widget/onboarding/onboarding_hoverable.dart';
import 'package:plot/widget/toast.dart';

/// Calendar providers surfaced in the onboarding "Connect your calendars"
/// step. Each entry maps a UI provider (with brand styling and label) to the
/// connector twist that backs it, identified by the `plotTwistId` from the
/// connector's `package.json` (which lands in the database as
/// `twist_package_id`).
class _CalendarProvider {
  const _CalendarProvider({
    required this.provider,
    required this.twistPackageId,
  });

  final AuthProvider provider;
  final String twistPackageId;
}

const _calendarProviders = <_CalendarProvider>[
  _CalendarProvider(
    provider: AuthProvider.google,
    twistPackageId: '2ed4fcf8-6524-410f-b318-f9316e71c8b0',
  ),
  _CalendarProvider(
    provider: AuthProvider.microsoft,
    twistPackageId: 'cf518010-30c1-4594-b3df-295a19d65459',
  ),
];

/// Per-provider data prepared on widget mount: the connector twist, a draft
/// twist_instance to attach the OAuth result to, and the matching provider
/// definition (with scopes) returned by the draft's `/integrations` endpoint.
class _ProviderData {
  _ProviderData({
    required this.twist,
    required this.draftId,
    required this.provider,
  });

  final Twist twist;
  final String draftId;
  final TwistProvider provider;
  bool activated = false;
}

/// Renders the content of the "Connect your calendars" onboarding step.
///
/// Lists any calendars the user has already connected and a brand-styled
/// auth button for each supported provider. Tapping a button runs the
/// provider's OAuth flow inline (with a spinner on the same button); on
/// success, the draft is activated and an [EditSource] modal opens so the
/// user can pick channels and confirm. The step's Next/Continue button
/// (rendered by [OnboardingFullScreen]) advances to the next step whenever
/// the user chooses to proceed.
class OnboardingCalendars extends StatefulWidget {
  const OnboardingCalendars({super.key});

  @override
  State<OnboardingCalendars> createState() => _OnboardingCalendarsState();
}

class _OnboardingCalendarsState extends State<OnboardingCalendars> {
  List<SourceSummary> _connected = const [];
  final Map<String, _ProviderData> _byPackageId = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Clean up any drafts the user didn't activate so they don't accumulate.
    for (final data in _byPackageId.values) {
      if (!data.activated) {
        unawaited(_safeDeleteDraft(data.draftId));
      }
    }
    super.dispose();
  }

  static Future<void> _safeDeleteDraft(String draftId) async {
    try {
      await TwistApi.deleteDraft(draftId);
    } catch (e, t) {
      log.warning('Failed to delete onboarding draft $draftId', e, t);
    }
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        TwistApi.getAllTwists(),
        TwistApi.getSourcesSummary(),
      ]);
      final twists = results[0] as List<Twist>;
      final sources = results[1] as List<SourceSummary>;
      if (!mounted) return;

      // Look up the connector twist for each provider, then create a draft
      // and fetch its integrations in parallel so we can render the
      // brand-styled AuthButton with proper scopes immediately.
      final futures = <Future<MapEntry<String, _ProviderData>?>>[];
      for (final p in _calendarProviders) {
        final twist = twists.firstWhereOrNull(
          (t) => t.twistPackageId == p.twistPackageId,
        );
        if (twist == null) continue;
        futures.add(_prepareDraft(twist, p.provider));
      }
      final entries = await Future.wait(futures);
      if (!mounted) return;

      setState(() {
        _connected = sources;
        for (final entry in entries) {
          if (entry == null) continue;
          _byPackageId[entry.key] = entry.value;
        }
        _loading = false;
      });
    } catch (e, t) {
      log.warning('Failed to load onboarding calendars', e, t);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<MapEntry<String, _ProviderData>?> _prepareDraft(
    Twist twist,
    AuthProvider provider,
  ) async {
    try {
      final draftId = await TwistApi.createDraft(
        twistId: twist.id,
        twistEnvironment: twist.environment,
        name: twist.name,
      );
      final integrations = await TwistApi.getIntegrations(draftId);
      final twistProvider = integrations.providers.firstWhereOrNull(
        (p) => p.provider == provider,
      );
      if (twistProvider == null) {
        await _safeDeleteDraft(draftId);
        return null;
      }
      final pkg = twist.twistPackageId;
      if (pkg == null) {
        await _safeDeleteDraft(draftId);
        return null;
      }
      return MapEntry(
        pkg,
        _ProviderData(
          twist: twist,
          draftId: draftId,
          provider: twistProvider,
        ),
      );
    } catch (e, t) {
      log.warning('Failed to prepare draft for ${twist.name}', e, t);
      return null;
    }
  }

  Future<void> _onAuthSuccess(_ProviderData data) async {
    data.activated = true;
    String? activatedId;
    try {
      // Activate the draft as a personal connection. The user can re-assign
      // a team later from Manage connections; the onboarding step is
      // intentionally minimal.
      await TwistApi.activateDraft(
        draftId: data.draftId,
        name: data.twist.name,
      );
      activatedId = data.draftId;
    } catch (e, t) {
      log.warning('Failed to activate ${data.twist.name}', e, t);
      if (mounted) {
        context.showToast(
          message: 'Failed to set up ${data.twist.name}. Please try again.',
          isError: true,
        );
      }
      // Re-create a fresh draft so the user can retry.
      data.activated = false;
      return;
    }

    // Open EditSource so the user can pick channels and confirm. After it
    // closes, refresh the connected list and prepare a new draft so the
    // user can connect another account of the same provider.
    if (mounted) {
      EditSource.preloadIntegrations(activatedId);
      await EditSource(
        twistInstanceId: activatedId,
        name: data.twist.name,
        isNewlyActivated: true,
        dismissable: true,
        logoUrl: data.twist.logoUrl,
        logoUrlDark: data.twist.logoUrlDark,
      ).run(context);
    }

    if (mounted) await _refreshAfterActivation(data);
  }

  Future<void> _refreshAfterActivation(_ProviderData data) async {
    // Reload the sources summary and create a fresh draft for the same
    // provider so "Add another account" works without restarting the step.
    try {
      final sources = await TwistApi.getSourcesSummary();
      _ProviderData? newData;
      final twist = data.twist;
      newData = (await _prepareDraft(twist, data.provider.provider))?.value;
      if (!mounted) return;
      setState(() {
        _connected = sources;
        final pkg = twist.twistPackageId;
        if (pkg != null) {
          if (newData != null) {
            _byPackageId[pkg] = newData;
          } else {
            _byPackageId.remove(pkg);
          }
        }
      });
    } catch (e, t) {
      log.warning('Failed to refresh after activation', e, t);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 80,
        child: Center(
          child: _WhiteSpinner(),
        ),
      );
    }

    final calendarPackageIds =
        _calendarProviders.map((p) => p.twistPackageId).toSet();
    final connectedCalendars = _connected
        .where((s) =>
            s.twistPackageId != null &&
            calendarPackageIds.contains(s.twistPackageId) &&
            // Exclude drafts and partially-set-up sources (OAuth completed
            // but EditSource closed without picking channels). They linger
            // in /sources/summary but aren't real connections from the
            // user's perspective. ManageConnections applies the same rule.
            s.enabledCount > 0)
        .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final source in connectedCalendars)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ConnectedRow(
              source: source,
              onTap: () => _editConnection(source),
            ),
          ),
        if (connectedCalendars.isNotEmpty) ...[
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
        for (final p in _calendarProviders)
          if (_byPackageId[p.twistPackageId] case final data?)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Center(
                child: AuthButton.connect(
                  key: ValueKey(
                    'onboarding_auth_${p.provider.name}_${data.draftId}',
                  ),
                  provider: p.provider,
                  scopes: data.provider.scopes,
                  twistInstanceId: data.draftId,
                  onSuccess: () => _onAuthSuccess(data),
                ),
              ),
            ),
      ],
    );
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

extension<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}

/// Tiny spinner drawn in white for use on the colored onboarding overlay.
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
          border: Border.all(
            color: const Color(0x66FFFFFF),
            width: 2,
          ),
          gradient: const SweepGradient(
            colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF)],
          ),
        ),
      ),
    );
  }
}

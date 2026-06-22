import 'package:collection/collection.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'command.dart';
import 'upgrade.dart' show ShowUpgradeOptions;

import 'package:plot/analytics/tracker.dart';
import 'package:plot/analytics/profile.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/widget/auth_button.dart' show AuthButton;
import 'package:plot/store/store.dart';
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/api/twist_permission.dart' show PermissionFlag;
import 'package:plot/state/subscription_service.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/setup_link_channels.dart';
import 'package:plot/widget/widget.dart';
import 'logging.dart';

/// Compare environments in order: public, review, private, personal
int _compareEnvironment(String a, String b) {
  const envOrder = ['public', 'review', 'private', 'personal'];
  final aIndex = envOrder.indexOf(a);
  final bIndex = envOrder.indexOf(b);
  final aVal = aIndex == -1 ? envOrder.length : aIndex;
  final bVal = bIndex == -1 ? envOrder.length : bIndex;
  return aVal.compareTo(bVal);
}

// ============================================================================
// Entry point: Manage Connections and Twists
// ============================================================================

class ManageConnectionsAndTwists extends ShowCommands {
  ManageConnectionsAndTwists()
    : super(
        title: 'Connections and twists',
        icon: PlotIcon.connection,
        commands: Commands(
          groups: [
            StaticCommandGroup(commands: [ManageConnections(), ManageTwists()]),
          ],
        ),
      );
}

// ============================================================================
// Manage Connections
// ============================================================================

/// Item model for the ManageConnections SelectModal.
sealed class _ConnectionItem {
  String get filterText;
}

class _ActiveSource extends _ConnectionItem {
  final String id; // twist_instance_id
  final String name;
  final String? twistName;
  final String? accountLabel;
  final String? logoUrl;
  final String? logoUrlDark;
  final AuthProvider? provider;
  final int enabledCount;
  final String? teamName;
  final bool showScopeBadge;
  final bool premium;

  _ActiveSource({
    required this.id,
    required this.name,
    this.twistName,
    this.accountLabel,
    this.logoUrl,
    this.logoUrlDark,
    this.provider,
    required this.enabledCount,
    this.teamName,
    this.showScopeBadge = false,
    this.premium = false,
  });

  @override
  String get filterText => '${accountLabel ?? ''} ${twistName ?? name}'.trim();
}

class _AvailableSource extends _ConnectionItem {
  final Twist twist;

  _AvailableSource(this.twist);

  @override
  String get filterText => '${twist.name} ${twist.description ?? ''}';
}

class _UpcomingConnection extends _ConnectionItem {
  final UpcomingConnection connection;
  bool hasVoted;
  int votes;

  _UpcomingConnection({
    required this.connection,
    required this.hasVoted,
    required this.votes,
  });

  @override
  String get filterText => '${connection.name} ${connection.category}';
}

class ManageConnections extends Command {
  ManageConnections({this.keepCache = false})
    : super(
        title: 'Connections',
        description: 'Sync your accounts and data into Plot.',
        icon: PlotIcon.connection,
        eventObject: EventObject.twist,
        eventAction: EventAction.opened,
      );

  /// Skip clearing [_dataCache] / [_upcomingCache] when opening the modal so
  /// callers that prewarmed via [prewarm] don't immediately discard their work.
  final bool keepCache;

  /// Populate [_dataCache] (and [_upcomingCache]) without opening the modal so
  /// the modal can render its content immediately on first frame. Errors are
  /// swallowed — the modal will retry and surface failures normally.
  static Future<void> prewarm() async {
    if (_dataCache != null) return;
    try {
      await _loadData();
    } catch (_) {
      // Modal will retry and surface errors via _fetchItems.
    }
  }

  /// Reactively reports whether any *active* connection needs re-auth. A
  /// connection counts only when it still has at least one enabled channel —
  /// a connection whose channels are all disabled is dormant and excluded from
  /// the active list below (`enabledCount == 0`) and from quota counts, so it
  /// must not light up the reconnect affordances. See [TwistConnection.active].
  Widget _activeReauthBuilder(Widget Function(bool needsReauth) build) {
    return StreamBuilder<bool>(
      stream: TwistConnection.watchActiveNeedsReauth(),
      initialData: false,
      builder: (context, snap) => build(snap.data ?? false),
    );
  }

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) {
    return _activeReauthBuilder(
      (needsReauth) => FaIcon(
        needsReauth ? PlotIcon.plugCircleExclamation : PlotIcon.connection,
        size: context.theme.iconSizes.base,
        color: needsReauth ? context.theme.colors.destructive : null,
      ),
    );
  }

  @override
  Widget? buildDescription(BuildContext context) {
    return _activeReauthBuilder((needsReauth) {
      if (!needsReauth) {
        return Text(
          description!,
          style: context.theme.typography.sm.copyWith(
            color: context.theme.plotColors.muted,
          ),
        );
      }
      return Text(
        'Action required to reconnect.',
        style: context.theme.typography.sm.copyWith(
          color: context.theme.colors.destructive,
        ),
      );
    });
  }

  /// Cached upcoming connections data, fetched once per ManageConnections session.
  static ({List<UpcomingConnection> connections, Set<String> votedByUser})?
  _upcomingCache;

  /// Cached pre-built item lists, populated on first fetch and reused for
  /// client-side filtering on subsequent keystrokes.
  static ({
    List<_ActiveSource> active,
    List<_AvailableSource> available,
    List<_UpcomingConnection> upcoming,
    UsageData? usage,
  })?
  _dataCache;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (!keepCache) {
      _upcomingCache = null; // Reset cache for each new session
      _dataCache = null;
    }
    try {
      Future<void> Function()? refreshFn;
      await SelectModal.open<_ConnectionItem>(
        context,
        items: (search) => _fetchItems(search),
        itemBuilder: (item, isLoading) => _buildItem(item, isLoading),
        onRefreshNeeded: (refresh) => refreshFn = refresh,
        onSelect: (ctx, item, _) async {
          String? archivedActiveId;
          if (item is _ActiveSource) {
            await EditSource(
              twistInstanceId: item.id,
              name: item.twistName ?? item.name,
              accountLabel: item.accountLabel,
              logoUrl: item.logoUrl,
              logoUrlDark: item.logoUrlDark,
            ).run(ctx);
            // The archive command sets archivedAt on the local TwistInstance,
            // so we can detect the archive flow without plumbing a return value.
            final ti = TwistInstance.fromCache(Uuid.fromString(item.id));
            if (ti?.archivedAt != null) {
              archivedActiveId = item.id;
            }
          } else if (item is _AvailableSource) {
            await AddSourceDetail(item.twist).run(ctx);
            final connectedDraftId = AddSourceDetail.lastConnectedDraftId;
            final connectedTeamId = AddSourceDetail.lastConnectedTeamId;
            final completedInSetup = AddSourceDetail.lastActivatedInSetupModal;
            AddSourceDetail.lastConnectedDraftId = null;
            AddSourceDetail.lastConnectedTeamId = null;
            AddSourceDetail.lastActivatedInSetupModal = false;
            if (shouldOpenChannelSetupAfterConnect(
                  connectedDraftId: connectedDraftId,
                  hasProviders: item.twist.providers.isNotEmpty,
                  completedInSetupModal: completedInSetup,
                ) &&
                ctx.mounted) {
              // OAuth: the instance is still a DRAFT. Push EditSource on top of
              // the connections list so the user picks channels; saving there
              // activates the draft, and abandoning deletes it. Popping
              // EditSource returns the user to ManageConnections naturally.
              await EditSource(
                twistInstanceId: connectedDraftId!,
                name: item.twist.name,
                isNewlyActivated: true,
                initialTeamHint: connectedTeamId,
              ).run(ctx);
            }
            // Non-OAuth, or OAuth where setup completed in the AddSourceDetail
            // modal itself: channels configured during setup, just refresh +
            // stay.
          } else if (item is _UpcomingConnection) {
            await _NotifyUpcomingConnection(item).run(ctx);
          }
          // Optimistically drop an archived source from the cache so the list
          // reflects the change immediately; otherwise invalidate so we refetch.
          final cache = _dataCache;
          if (archivedActiveId != null && cache != null) {
            _dataCache = (
              active: cache.active
                  .where((s) => s.id != archivedActiveId)
                  .toList(),
              available: cache.available,
              upcoming: cache.upcoming,
              usage: cache.usage,
            );
          } else {
            _dataCache = null;
          }
          await refreshFn?.call();
          return false; // Keep SelectModal open
        },
      );

      return const CommandSkipped();
    } on ApiException catch (e, t) {
      log.warning('Failed to load sources', e, t);
      return const CommandMessage(
        'Could not connect to Plot servers.',
        isError: true,
      );
    } on NetworkException catch (e, t) {
      log.warning('Failed to load sources', e, t);
      return const CommandMessage(
        'Could not connect to Plot servers.',
        isError: true,
      );
    }
  }

  static Future<List<SelectGroup<_ConnectionItem>>> _fetchItems(
    String? search,
  ) async {
    // Use cached data for filtered searches; only hit the network on the
    // initial load (search == null) or when the cache is empty (refresh).
    if (_dataCache == null) {
      await _loadData();
    }
    final cache = _dataCache!;

    // Filter by search
    List<_ConnectionItem> filteredActive = cache.active;
    List<_ConnectionItem> filteredAvailable = cache.available;
    List<_ConnectionItem> filteredUpcoming = cache.upcoming;
    if (search != null && search.isNotEmpty) {
      final words = search.toLowerCase().trim().split(RegExp(r'\s+'));
      bool matches(_ConnectionItem item) {
        final text = item.filterText.toLowerCase();
        return words.every(
          (w) => text.split(RegExp(r'[\s/]+')).any((fw) => fw.startsWith(w)),
        );
      }

      filteredActive = cache.active.where(matches).toList();
      filteredAvailable = cache.available.where(matches).toList();
      filteredUpcoming = cache.upcoming.where(matches).toList();
    }

    final usage = cache.usage;
    final activeTitle = usage != null
        ? 'Active connections ${_usageSuffix(usage, _ResourceType.connections)}'
        : 'Active connections';

    return [
      if (filteredActive.isNotEmpty || usage != null)
        SelectGroup(title: activeTitle, items: filteredActive),
      if (filteredAvailable.isNotEmpty)
        SelectGroup(title: 'Available connections', items: filteredAvailable),
      if (filteredUpcoming.isNotEmpty)
        SelectGroup(title: 'Upcoming connections', items: filteredUpcoming),
    ];
  }

  /// Fetches data from the network and populates [_dataCache].
  static Future<void> _loadData() async {
    final futures = <Future<dynamic>>[
      TwistApi.getSourcesSummary(),
      TwistApi.getAllTwists(),
      UpgradeApi.getUsage().then<UsageData?>((r) => r).catchError((_) => null),
    ];
    if (_upcomingCache == null) {
      futures.add(
        TwistApi.getUpcomingConnections()
            .then<
              ({List<UpcomingConnection> connections, Set<String> votedByUser})?
            >((r) => r)
            .catchError((_) => null),
      );
    }
    final results = await Future.wait(futures);

    final summaries = results[0] as List<SourceSummary>;
    final allTwists = results[1] as List<Twist>;
    final usage = results[2] as UsageData?;
    if (results.length > 3) {
      _upcomingCache =
          results[3]
              as ({
                List<UpcomingConnection> connections,
                Set<String> votedByUser,
              })?;
    }
    final upcomingResult = _upcomingCache;

    // Build active connections from summaries. Only show the scope badge
    // (team name / "Personal") when the user actually belongs to a team —
    // otherwise the "Personal" badge confused users into thinking it meant
    // the connection was assigned to their Personal priority.
    final showScopeBadge = usage != null && usage.teams.isNotEmpty;
    final activeItems = <_ActiveSource>[];
    for (final summary in summaries) {
      activeItems.add(
        _ActiveSource(
          id: summary.id,
          name: summary.name,
          twistName: summary.twistName,
          accountLabel: summary.accountLabel,
          logoUrl: summary.logoUrl,
          logoUrlDark: summary.logoUrlDark,
          provider: summary.provider,
          enabledCount: summary.enabledCount,
          teamName: summary.teamName,
          showScopeBadge: showScopeBadge,
          premium: summary.premium,
        ),
      );
    }

    // Exclude sources with no enabled channels — they don't count as active
    activeItems.removeWhere((item) => item.enabledCount == 0);

    // Build available connections (all source twists, including active ones
    // since additional accounts can be added)
    final availableItems = allTwists
        .where((t) => t.isSource)
        .map((t) => _AvailableSource(t))
        .toList();

    // Sort by name, then environment (public first)
    activeItems.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    availableItems.sort((a, b) {
      final nameComparison = a.twist.name.toLowerCase().compareTo(
        b.twist.name.toLowerCase(),
      );
      if (nameComparison != 0) return nameComparison;
      return _compareEnvironment(a.twist.environment, b.twist.environment);
    });

    // Build upcoming connections (exclude names that match available sources)
    final availableSourceNames = allTwists
        .where((t) => t.isSource)
        .map((t) => t.name)
        .toSet();
    final upcomingItems = <_UpcomingConnection>[];
    if (upcomingResult != null) {
      for (final conn in upcomingResult.connections) {
        if (!availableSourceNames.contains(conn.name)) {
          upcomingItems.add(
            _UpcomingConnection(
              connection: conn,
              hasVoted: upcomingResult.votedByUser.contains(conn.name),
              votes: conn.votes,
            ),
          );
        }
      }
    }

    _dataCache = (
      active: activeItems,
      available: availableItems,
      upcoming: upcomingItems,
      usage: usage,
    );
  }

  static Widget _buildItem(_ConnectionItem item, bool isLoading) {
    switch (item) {
      case _ActiveSource():
        return _ActiveSourceRow(item: item, isLoading: isLoading);
      case _AvailableSource():
        return _AvailableSourceRow(item: item, isLoading: isLoading);
      case _UpcomingConnection():
        return _UpcomingConnectionRow(item: item, isLoading: isLoading);
    }
  }
}

class _ActiveSourceRow extends StatelessWidget {
  const _ActiveSourceRow({required this.item, this.isLoading = false});
  final _ActiveSource item;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<TwistConnectionRow>>(
      stream: TwistConnection.watchForInstance(Uuid.fromString(item.id)),
      initialData: const [],
      builder: (context, snap) {
        final needsReauth = (snap.data ?? const []).any((c) => c.needsReauth);
        return _buildRow(context, needsReauth: needsReauth);
      },
    );
  }

  Widget _buildRow(BuildContext context, {required bool needsReauth}) {
    final theme = context.theme;

    final hasLabel = item.accountLabel != null && item.accountLabel!.isNotEmpty;
    final subtitle = hasLabel ? item.accountLabel! : 'Set label';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (isLoading)
            Spinner(
              size: theme.iconSizes.base,
              color: theme.colors.mutedForeground,
            )
          else if (needsReauth)
            SizedBox(
              width: theme.iconSizes.base,
              height: theme.iconSizes.base,
              child: Center(
                child: FaIcon(
                  PlotIcon.plugCircleExclamation,
                  size: theme.iconSizes.base,
                  color: theme.colors.destructive,
                ),
              ),
            )
          else
            _SourceLogo(
              logoUrl: item.logoUrl,
              logoUrlDark: item.logoUrlDark,
              provider: item.provider,
              size: theme.iconSizes.base,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              children: [
                if (needsReauth) ...[
                  Text(
                    'Reconnect',
                    style: TextStyle(
                      fontSize: theme.typography.md.fontSize,
                      color: theme.colors.destructive,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  item.twistName ?? item.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: theme.typography.md.fontSize,
                    color: theme.colors.foreground,
                  ),
                ),
                if (item.premium) ...[
                  const SizedBox(width: 6),
                  const ProBadge(),
                ],
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    subtitle,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: theme.typography.md.fontSize,
                      color: theme.colors.mutedForeground,
                      fontStyle: hasLabel ? FontStyle.normal : FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (item.showScopeBadge)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colors.secondary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                item.teamName ?? 'Personal',
                style: TextStyle(
                  fontSize: theme.typography.xs.fontSize,
                  color: theme.colors.mutedForeground,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AvailableSourceRow extends StatelessWidget {
  const _AvailableSourceRow({required this.item, this.isLoading = false});
  final _AvailableSource item;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (isLoading)
            Spinner(
              size: theme.iconSizes.base,
              color: theme.colors.mutedForeground,
            )
          else
            _SourceLogo(
              logoUrl: item.twist.logoUrl,
              logoUrlDark: item.twist.logoUrlDark,
              provider: item.twist.providers.firstOrNull,
              size: theme.iconSizes.base,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              children: [
                Text(
                  item.twist.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: theme.typography.md.fontSize,
                    color: theme.colors.foreground,
                  ),
                ),
                if (item.twist.premium) ...[
                  const SizedBox(width: 6),
                  const ProBadge(),
                ],
                if (item.twist.environment != 'public') ...[
                  const SizedBox(width: 6),
                  _EnvironmentBadge(environment: item.twist.environment),
                ],
                if (item.twist.description != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      item.twist.description!,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: theme.typography.md.fontSize,
                        color: theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UpcomingConnectionRow extends StatelessWidget {
  const _UpcomingConnectionRow({required this.item, this.isLoading = false});
  final _UpcomingConnection item;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (isLoading)
            Spinner(
              size: theme.iconSizes.base,
              color: theme.colors.mutedForeground,
            )
          else
            _SourceLogo(
              logoUrl: item.connection.logo,
              logoUrlDark: item.connection.logoDark,
              size: theme.iconSizes.base,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              children: [
                Text(
                  item.connection.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: theme.typography.md.fontSize,
                    color: theme.colors.foreground,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    item.connection.description ?? item.connection.category,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: theme.typography.md.fontSize,
                      color: theme.colors.mutedForeground,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (item.hasVoted)
            Icon(
              PlotIcon.notification,
              size: theme.iconSizes.xs,
              color: theme.colors.mutedForeground,
            ),
        ],
      ),
    );
  }
}

class _NotifyUpcomingConnection extends ShowForm {
  _NotifyUpcomingConnection(this.item)
    : super(
        title: item.connection.name,
        icon: PlotIcon.connection,
        form: (context) => _buildForm(item),
      );

  final _UpcomingConnection item;

  static Future<FormData> _buildForm(_UpcomingConnection item) async {
    return FormData(
      title: item.connection.name,
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'header',
              builder: (context) {
                final theme = context.theme;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SourceLogo(
                        logoUrl: item.connection.logo,
                        logoUrlDark: item.connection.logoDark,
                        size: 32,
                      ),
                      if (item.connection.description != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          item.connection.description!,
                          style: TextStyle(
                            fontSize: theme.typography.md.fontSize,
                            color: theme.colors.foreground,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        item.connection.category,
                        style: TextStyle(
                          fontSize: theme.typography.sm.fontSize,
                          color: theme.colors.mutedForeground,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Syncs: ${item.connection.entities.join(', ')}',
                        style: TextStyle(
                          fontSize: theme.typography.sm.fontSize,
                          color: theme.colors.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            if (item.hasVoted)
              FormInfo(
                key: 'voted',
                text: "You'll be notified when this connection is available.",
              ),
            if (!item.hasVoted)
              FormButton(
                key: 'vote',
                isPrimary: true,
                buildCommand: (_) => _VoteForConnectionCommand(item),
              ),
          ],
        ),
      ],
    );
  }
}

class _VoteForConnectionCommand extends Command {
  _VoteForConnectionCommand(this.item)
    : super(
        title: 'Notify me when available',
        icon: PlotIcon.notification,
        eventObject: EventObject.twist,
        eventAction: EventAction.updated,
      );

  final _UpcomingConnection item;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final newVotes = await TwistApi.voteForConnection(item.connection.name);
      item.hasVoted = true;
      item.votes = newVotes;
      return CommandMessage(
        "You'll be notified when ${item.connection.name} is available.",
      );
    } catch (e, t) {
      log.warning('Failed to vote for connection', e, t);
      return const CommandMessage(
        'Could not register interest.',
        isError: true,
      );
    }
  }
}

/// Badge showing the environment name for non-public twists/sources.
class _EnvironmentBadge extends StatelessWidget {
  const _EnvironmentBadge({required this.environment});
  final String environment;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final label = environment[0].toUpperCase() + environment.substring(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colors.secondary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: theme.typography.xs.fontSize,
          color: theme.colors.mutedForeground,
        ),
      ),
    );
  }
}

/// Displays a source logo from URL, falling back to provider icon.
class _SourceLogo extends StatelessWidget {
  const _SourceLogo({
    this.logoUrl,
    this.logoUrlDark,
    this.provider,
    required this.size,
  });

  final String? logoUrl;
  final String? logoUrlDark;
  final AuthProvider? provider;
  final double size;

  @override
  Widget build(BuildContext context) {
    final isDark = context.colour.brightness == Brightness.dark;
    final url = isDark && logoUrlDark != null ? logoUrlDark : logoUrl;
    if (url != null) {
      return LogoImage(url: url, size: size, fallback: _fallback());
    }
    return _fallback();
  }

  Widget _fallback() {
    if (provider != null) {
      return ProviderIcon(provider: provider!, size: size);
    }
    return SizedBox(
      width: size,
      height: size,
      child: Icon(PlotIcon.connection, size: size * 0.8),
    );
  }
}

// ============================================================================
// Shared limit/upgrade helpers
// ============================================================================

enum _ResourceType { connections, twists }

/// The freshest usage the app knows about: the [SubscriptionService] snapshot
/// (kept current via websocket broadcast and app refocus) when available,
/// otherwise the [fallback] captured when the form first opened. Setup-modal
/// gates read through this so they re-evaluate against a just-completed
/// upgrade — including one done out-of-band in a browser — instead of the
/// stale snapshot they were built from.
UsageData _liveUsage(UsageData fallback) =>
    SubscriptionService.instance.usage ?? fallback;

/// Refresh the [SubscriptionService] and return its usage, falling back to the
/// [ManageConnections] cache or a direct fetch if the service couldn't load.
/// Setup forms seed their initial usage from this so the value they render and
/// the notifier they bind to via `refreshOn` share one source of truth.
Future<UsageData> _freshUsage() async {
  await SubscriptionService.instance.ensureFresh();
  return SubscriptionService.instance.usage ??
      ManageConnections._dataCache?.usage ??
      await UpgradeApi.getUsage();
}

/// Returns the at-limit command for a connection-limit case. Opens the
/// upgrade picker on every distribution channel — on App Store builds
/// that picker triggers StoreKit IAP; on web/DMG it routes to
/// `${Env.siteRoot}/upgrade`. Team limits route to a no-op toast since
/// Team purchases are admin-only and not IAP-available.
Command _connectionAtLimitCommand() =>
    ShowUpgradeOptions(title: 'Upgrade to add more connections');

/// Returned when a Free/Core user tries to add a premium connection.
Command _premiumBlockedCommand() => ShowUpgradeOptions(
  title: 'Upgrade to Pro to add a Pro connection',
  subtitle:
      'LinkedIn (and other Pro connectors) are included with Pro. '
      'Your current plan only includes standard connections.',
);

/// Returned when a Pro user has used their included premium connection,
/// or a Team is too close to the pool ceiling to accommodate one
/// (premium connections count as 3 from the team pool).
Command _premiumAtLimitCommand({required bool isTeam}) => ShowUpgradeOptions(
  title: isTeam
      ? 'Pro connection limit reached'
      : "You've used your included Pro connection",
  subtitle: isTeam
      ? "Pro connections count as 3 from your team's pool. "
            'Add another group of 50 connections to keep going. '
            'Dedicated Pro add-ons are coming soon.'
      : 'Pro includes one Pro connection. Pro add-ons are coming '
            "soon — we'll let you know.",
);

/// Convenience wrapper around [_evaluatePremium]: returns a ready-to-run
/// command for the premium-block / premium-at-limit cases, or null when the
/// connector is not premium or the standard limit-check should proceed.
Command? _premiumGateCommand({
  required UsageData usage,
  required String owner, // 'personal' or team id
  required bool isPremium,
}) {
  if (!isPremium) return null;
  switch (_evaluatePremium(usage: usage, owner: owner)) {
    case _PremiumGate.allowed:
      return null;
    case _PremiumGate.blocked:
      return _premiumBlockedCommand();
    case _PremiumGate.atLimit:
      return _premiumAtLimitCommand(isTeam: owner != 'personal');
  }
}

/// Onboarding-facing gate: the upgrade [Command] to run instead of opening
/// setup for a premium connector, or null to proceed. Mirrors the preemptive
/// gate [AddSourceDetail] applies — we only gate on the tile tap when the user
/// has no team to fall back to; team-aware gating happens inside the setup
/// modal. Pure (no context/IO) so it is unit-testable.
Command? premiumOnboardingGate({
  required UsageData usage,
  required bool isPremium,
}) {
  if (!isPremium || usage.teams.isNotEmpty) return null;
  return _premiumGateCommand(usage: usage, owner: 'personal', isPremium: true);
}

enum _PremiumGate { allowed, atLimit, blocked }

/// Decide whether the selected scope can accept another premium connection.
/// Returns:
///   - [_PremiumGate.allowed] when no further gating is needed (regular
///     pool checks still apply for `weighted` scopes — handled separately).
///   - [_PremiumGate.atLimit] when the scope's premium credit pool is
///     exhausted, or a `weighted` scope can't fit another premium.
///   - [_PremiumGate.blocked] when the scope's plan doesn't allow premium.
_PremiumGate _evaluatePremium({
  required UsageData usage,
  required String owner, // 'personal' or team id
}) {
  final PremiumUsage? premium;
  final ResourceUsage? poolForWeighted;
  if (owner == 'personal') {
    premium = usage.personal.premium;
    poolForWeighted = null; // personal Pro is unlimited
  } else {
    final team = usage.teams.firstWhereOrNull((t) => t.id == owner);
    premium = team?.premium;
    poolForWeighted = team?.connections;
  }
  // Treat a missing payload (older server) as blocked so we never silently
  // let a premium slip through pre-rollout.
  if (premium == null) return _PremiumGate.blocked;
  switch (premium.policy) {
    case PremiumPolicy.blocked:
      return _PremiumGate.blocked;
    case PremiumPolicy.credits:
      return premium.isAtLimit ? _PremiumGate.atLimit : _PremiumGate.allowed;
    case PremiumPolicy.weighted:
      // Premium uses `weight` slots from the regular pool. If the pool has
      // fewer free slots than the weight, calling it "at limit" surfaces the
      // correct premium-specific upgrade message instead of the generic one.
      final weight = premium.weight ?? 1;
      if (poolForWeighted == null || poolForWeighted.limit == null) {
        return _PremiumGate.allowed; // unlimited pool — no gating
      }
      final remaining = poolForWeighted.limit! - poolForWeighted.count;
      return remaining < weight ? _PremiumGate.atLimit : _PremiumGate.allowed;
  }
}

/// Returns the at-limit command for a twist-limit case.
Command _twistAtLimitCommand() =>
    ShowUpgradeOptions(title: 'Upgrade to add more twists');

/// Message shown when the server returns plan_limit_exceeded for a connection.
/// Team limits are admin-driven so we never reference "Upgrade" for
/// non-admin members. On personal limits, the picker (triggered separately)
/// handles the upgrade flow — this message just reports the state.
String _planLimitConnectionMessage({
  required bool isTeam,
  required bool isAdmin,
}) {
  if (isTeam) {
    return isAdmin
        ? 'Your team has reached its connection limit.'
        : 'Your team has reached its connection limit. Contact your team admin.';
  }
  return "You've reached your connection limit.";
}

/// Message shown when the server returns plan_limit_exceeded for a twist.
String _planLimitTwistMessage({required bool isTeam, required bool isAdmin}) {
  if (isTeam) {
    return isAdmin
        ? 'Your team has reached its twist limit.'
        : 'Your team has reached its twist limit. Contact your team admin.';
  }
  return "You've reached your twist limit.";
}

/// Builds a usage suffix for group titles, e.g. "(1 of 2 personal, 40 Acme Co)".
String _usageSuffix(UsageData usage, _ResourceType resourceType) {
  final parts = <String>[];

  if (resourceType == _ResourceType.connections) {
    final personal = usage.personal.connections;
    parts.add(
      personal.isUnlimited
          ? '${personal.count} personal'
          : '${personal.count} of ${personal.limit} personal',
    );
    final premium = usage.personal.premium;
    // On Pro (policy=credits), surface the included premium slot so users see
    // why a second LinkedIn would be blocked. On Team scopes the premium
    // count folds into the regular pool via weighting, so we don't add a
    // separate line per-team.
    if (premium != null &&
        premium.policy == PremiumPolicy.credits &&
        premium.limit != null) {
      parts.add('Pro: ${premium.count} of ${premium.limit}');
    }
    for (final org in usage.teams) {
      parts.add(
        org.connections.isUnlimited
            ? '${org.connections.count} ${org.name}'
            : '${org.connections.count} of ${org.connections.limit} ${org.name}',
      );
    }
  } else {
    final personal = usage.personal.twists;
    parts.add(
      personal.isUnlimited
          ? '${personal.count} personal'
          : '${personal.count} of ${personal.limit} personal',
    );
  }

  return '(${parts.join(', ')})';
}

/// Standard source-modal items shared by [AddSourceDetail] (when reopening
/// a hosted-auth draft that already has an authenticated account) and
/// [EditSource]. Keeps the two modals visually identical: account header →
/// Label → Team → channels (with a `<entity> to sync` heading inside
/// [SetupSourceWidget]) → options. Callers append their own action button
/// (Add connection vs Save).
List<FormItem> _buildStandardSourceItems({
  required String twistInstanceId,
  required String sourceName,
  required String? logoUrl,
  required String? logoUrlDark,
  required TwistIntegrations integrations,
  required List<TeamUsage> teams,
  required String initialTeamId,
  required String initialLabel,
  required FormChannelListController channelListController,
  required ValueChanged<IntegrationChanges> onChannelChanges,
  required bool Function() channelsValidator,
  required bool setupMode,
  required bool isAccountBased,
  TwistOptionItems? optionItems,
  ValueNotifier<int>? refreshNotifier,
}) {
  return [
    // Connected account(s) sit at the very top, above the Label field, as the
    // header that identifies what's being configured.
    if (integrations.accounts.isNotEmpty)
      FormInfo(
        key: 'account_header',
        builder: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final account in integrations.accounts)
              SourceAccountRow(
                account: account,
                logoUrl: logoUrl,
                logoUrlDark: logoUrlDark,
              ),
          ],
        ),
      ),
    FormTextInput(
      key: 'account_label',
      label: 'Label',
      initialValue: initialLabel,
      required: false,
    ),
    if (teams.isNotEmpty)
      FormSelect<String>(
        key: 'team_id',
        label: 'Team',
        initialValue: initialTeamId,
        items: (search) async => ['personal', ...teams.map((t) => t.id)],
        titleBuilder: (id) => id == 'personal'
            ? 'Personal'
            : teams.firstWhere((t) => t.id == id).name,
      ),
    FormChannelList(
      key: 'integrations',
      controller: channelListController,
      validator: channelsValidator,
      builder: (context) => SetupSourceWidget(
        twistInstanceId: twistInstanceId,
        setupMode: setupMode,
        isAccountBased: isAccountBased,
        showAccounts: false,
        sourceName: sourceName,
        logoUrl: logoUrl,
        logoUrlDark: logoUrlDark,
        initialData: integrations,
        refreshNotifier: refreshNotifier,
        channelListController: channelListController,
        onChanged: onChannelChanges,
      ),
    ),
    if (optionItems != null) ...optionItems.items,
  ];
}

/// Edit an existing source — shows integrations, channels, and management options.
class EditSource extends ShowForm {
  EditSource({
    required this.twistInstanceId,
    required this.name,
    this.isAccountBased = true,
    this.isNewlyActivated = false,
    this.dismissable = false,
    this.logoUrl,
    this.logoUrlDark,
    this.accountLabel,
    this.initialTeamHint,
    super.subtitle,
  }) : super(
         title: isNewlyActivated ? 'Set up $name' : name,
         icon: PlotIcon.settings,
         form: (context) => _buildForm(
           twistInstanceId,
           name,
           isAccountBased,
           isNewlyActivated,
           dismissable,
           logoUrl: logoUrl,
           logoUrlDark: logoUrlDark,
           initialAccountLabel: accountLabel,
           initialTeamHint: initialTeamHint,
         ),
       );

  final String twistInstanceId;
  final String name;
  final bool isAccountBased;
  final String? logoUrl;
  final String? logoUrlDark;
  final String? accountLabel;

  /// For a just-connected OAuth draft ([isNewlyActivated]), the team resolved
  /// from the account's email domain (null = personal). Defaults the team
  /// selector so the connection is filed where AddSourceDetail computed.
  final String? initialTeamHint;

  /// When true, hides the Archive button (source was just set up).
  final bool isNewlyActivated;

  /// Set by [SaveSource] when it successfully activates a newly-connected
  /// draft. [run] reads it to decide whether to delete the draft on dismissal:
  /// if the user closed channel-setup without committing, the abandoned draft
  /// must be cleaned up so no orphaned connection lingers.
  static bool _committed = false;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Reset per open — statics persist across modal instances.
    if (isNewlyActivated) _committed = false;
    final result = await super.run(context);
    if (isNewlyActivated && !_committed) {
      // The user dismissed channel setup without committing. The instance is
      // still a draft (SaveSource never ran), so delete it.
      try {
        await TwistApi.deleteDraft(twistInstanceId);
      } catch (e, t) {
        log.warning('Failed to delete abandoned connection draft', e, t);
      }
    }
    return result;
  }

  /// When true, the modal renders a close (X) button in the header even
  /// when it's the only modal on the stack. Used by the onboarding flow,
  /// which opens EditSource directly without a parent modal to fall back
  /// to. Default: false — preserves the existing back-button-only header
  /// for callers that open EditSource from inside ManageConnections.
  final bool dismissable;

  /// Integrations prefetch kicked off by `_connectedAfterOAuth` so the first
  /// EditSource open after connecting doesn't block on a fresh network call
  /// (which otherwise leaves the ManageConnections list visible with an item
  /// spinner for ~1s between AddSourceDetail closing and EditSource opening).
  static Future<TwistIntegrations>? _preloadedIntegrations;
  static String? _preloadedFor;

  static void preloadIntegrations(String twistInstanceId) {
    _preloadedFor = twistInstanceId;
    _preloadedIntegrations = TwistApi.getIntegrations(twistInstanceId);
  }

  static Future<FormData> _buildForm(
    String twistInstanceId,
    String name,
    bool isAccountBased,
    bool isNewlyActivated,
    bool dismissable, {
    String? logoUrl,
    String? logoUrlDark,
    String? initialAccountLabel,
    String? initialTeamHint,
  }) async {
    final twistInstanceUuid = Uuid.fromString(twistInstanceId);

    Future<TwistIntegrations> integrationsF;
    if (_preloadedFor == twistInstanceId && _preloadedIntegrations != null) {
      integrationsF = _preloadedIntegrations!;
      _preloadedIntegrations = null;
      _preloadedFor = null;
    } else {
      integrationsF = TwistApi.getIntegrations(twistInstanceId);
    }
    final results = await Future.wait([
      integrationsF,
      _freshUsage(),
      TwistConnection.getForInstance(twistInstanceUuid),
    ]);
    var integrations = results[0] as TwistIntegrations;
    // Mutable so the onRefresh closure can re-read the live plan; sourced from
    // the SubscriptionService so the at-limit gate reacts to upgrades.
    var usage = results[1] as UsageData;
    var connections = results[2] as List<TwistConnectionRow>;
    var teams = usage.teams;

    final refreshNotifier = ValueNotifier<int>(0);
    final channelListController = FormChannelListController();

    Set<String> collectEnabled(List<TwistChannel> channels) {
      final result = <String>{};
      for (final s in channels) {
        if (s.enabled) result.add('${s.providerKey}:${s.id}');
        result.addAll(collectEnabled(s.children));
      }
      return result;
    }

    // Look up the current twist instance to get its current team_id and
    // account_label (fallback when not passed in explicitly).
    final currentTwistId = twistInstanceUuid;
    TwistInstanceRow? twistInstance = TwistInstance.fromCache(currentTwistId);
    twistInstance ??= await (Store.get.select(
      TwistInstance.table,
    )..where((t) => t.id.equals(currentTwistId.toBytes()))).getSingleOrNull();
    // For newly-activated sources whose draft was filed under personal because
    // the OAuth domain didn't match a team, prefer a team default so the
    // connection counts against team quota. Existing sources keep their
    // current scope. Skip teams already at their connection limit (e.g.
    // free-plan teams that can't host any connections) so we don't drop the
    // user into a scope they can't save into; fall back to personal in that
    // case and let the at-limit pre-check take over from there.
    String pickInitialTeamId() {
      if (twistInstance?.teamId != null) {
        return twistInstance!.teamId.toString();
      }
      if (!isNewlyActivated) return 'personal';
      // Prefer the team resolved from the OAuth account's email domain, as
      // long as it still exists and can host another connection.
      if (initialTeamHint != null) {
        final hinted = teams.firstWhereOrNull((t) => t.id == initialTeamHint);
        if (hinted != null && !hinted.connections.isAtLimit) {
          return hinted.id;
        }
      }
      for (final t in teams) {
        if (!t.connections.isAtLimit) return t.id;
      }
      return 'personal';
    }

    final initialTeamId = pickInitialTeamId();

    // Default scope group selections per provider, used by both the setup-
    // style reauth path and any future scope tweaks.
    final scopeGroupSelections = <String, Set<String>>{};
    for (final provider in integrations.providers) {
      if (provider.optionalScopes != null) {
        scopeGroupSelections[provider.provider.name] = {
          for (final group in provider.optionalScopes!)
            if (group.defaultEnabled) group.id,
        };
      }
    }

    Set<String> reauthProviderNames() =>
        connections.where((c) => c.needsReauth).map((c) => c.provider).toSet();

    List<StaticFormGroup> buildEditGroups() {
      // Prefer the server-fresh account_label from the integrations response
      // (which reflects the activateDraft fallback) over the potentially stale
      // local-store value. Then fall back to the team name or 'Personal' so
      // the Label field is never blank by default.
      final storedLabel =
          initialAccountLabel ??
          integrations.accountLabel ??
          twistInstance?.accountLabel;
      String fallbackLabel() {
        final teamName = integrations.teamName;
        if (teamName != null && teamName.isNotEmpty) return teamName;
        if (initialTeamId != 'personal') {
          final team = teams.firstWhereOrNull((t) => t.id == initialTeamId);
          if (team != null) return team.name;
        }
        return 'Personal';
      }

      // A just-connected draft has no user-set label yet — the server only
      // seeds a generic "Personal"/team placeholder into account_label. Prefer
      // the connected account's real identity (e.g. "Kris Braun") via
      // [initialLabelForSource] (the same default AddSourceDetail uses) instead
      // of defaulting to "Personal". Existing connections keep their stored
      // (possibly user-customized) label.
      final existingLabel = isNewlyActivated
          ? initialLabelForSource(integrations, teams)
          : (storedLabel != null && storedLabel.isNotEmpty)
              ? storedLabel
              : fallbackLabel();

      final hasOptions =
          integrations.optionsSchema != null &&
          integrations.optionsSchema!.isNotEmpty;
      final optionItems = hasOptions
          ? TwistOptionItems(
              options: integrations.optionsSchema!,
              initialConfig: integrations.optionsConfig,
            )
          : null;

      final initialEnabled = collectEnabled(integrations.channels);
      var integrationChanges = IntegrationChanges(
        selectedChannels: Set.of(initialEnabled),
      );

      return [
        StaticFormGroup(
          items: _buildStandardSourceItems(
            twistInstanceId: twistInstanceId,
            sourceName: name,
            logoUrl: logoUrl,
            logoUrlDark: logoUrlDark,
            integrations: integrations,
            teams: teams,
            initialTeamId: initialTeamId,
            initialLabel: existingLabel,
            channelListController: channelListController,
            onChannelChanges: (changes) {
              integrationChanges = changes;
            },
            channelsValidator: () =>
                integrationChanges.selectedChannels.isNotEmpty,
            setupMode: isNewlyActivated,
            isAccountBased: isAccountBased,
            optionItems: optionItems,
            refreshNotifier: refreshNotifier,
          ),
        ),
        StaticFormGroup(
          items: [
            FormButton(
              key: 'save',
              isPrimary: true,
              buildCommand: (values) {
                final owner = values['team_id'] as String? ?? initialTeamId;

                // Enforce the limit on newly-connected sources (saving here
                // activates the draft, which increments the count and would
                // 403 with plan_limit_exceeded server-side) and on scope
                // changes (the destination's count will increment on save).
                // Existing connections saving in place are exempt — they
                // already count toward their current scope.
                if (isNewlyActivated || owner != initialTeamId) {
                  final live = _liveUsage(usage);
                  final premiumGate = _premiumGateCommand(
                    usage: live,
                    owner: owner,
                    isPremium: integrations.premium,
                  );
                  if (premiumGate != null) return premiumGate;
                  final team = live.teams.firstWhereOrNull((t) => t.id == owner);
                  final atLimit = team != null
                      ? team.connections.isAtLimit
                      : live.personal.connections.isAtLimit;
                  if (atLimit) {
                    return _connectionAtLimitCommand();
                  }
                }

                final label =
                    (values['account_label'] as String?)?.trim() ?? '';
                return SaveSource(
                  twistInstanceId: twistInstanceId,
                  name: name,
                  initialEnabled: initialEnabled,
                  changes: integrationChanges,
                  optionItems: optionItems,
                  isNewlyActivated: isNewlyActivated,
                  teamId: owner == 'personal' ? null : owner,
                  accountLabel: label.isEmpty ? null : label,
                );
              },
            ),
            if (!isNewlyActivated) ...[
              FormButton(
                key: 'archive',
                skipValidation: true,
                destructive: true,
                buildCommand: (_) => PromptToArchiveSource(
                  twistInstanceId: twistInstanceId,
                  name: name,
                ),
              ),
            ],
          ],
        ),
      ];
    }

    StaticFormGroup buildReauthGroup() {
      final reauthFilter = reauthProviderNames();
      final providersNeedingReauth = integrations.providers
          .where((p) => reauthFilter.contains(p.provider.name))
          .toList();

      return StaticFormGroup(
        items: [
          FormInfo(
            key: 'reauth_message',
            text: providersNeedingReauth.length > 1
                ? 'Reconnect to keep $name in sync.'
                : 'Reconnect $name to resume syncing.',
          ),
          for (final provider in providersNeedingReauth)
            FormInfo(
              key: 'auth_${provider.provider.name}',
              divider: false,
              builder: (formContext) {
                // Pre-select the account that needs re-auth so the provider
                // can skip its account chooser when possible. Only Google and
                // Microsoft honor this on the server (login_hint).
                final existingAccount = integrations.accounts.firstWhereOrNull(
                  (a) => a.provider == provider.provider,
                );
                return Padding(
                  padding: EdgeInsets.only(
                    left: formContext.theme.spacing.xl,
                    right: formContext.theme.spacing.xl,
                    bottom: formContext.theme.spacing.lg,
                  ),
                  child: _AuthWithScopeToggles(
                    provider: provider,
                    twistInstanceId: twistInstanceId,
                    initialEnabledGroups:
                        scopeGroupSelections[provider.provider.name],
                    onScopeGroupsChanged: (groups) {
                      scopeGroupSelections[provider.provider.name] = groups;
                    },
                    accountHint: existingAccount?.email,
                    accountLabel:
                        existingAccount?.email ?? existingAccount?.name,
                    onSuccess: () async {
                      // Pull fresh connection state so needs_reauth flips
                      // off, then refresh the form to swap to the normal
                      // edit view.
                      await TwistConnection.pull();
                      if (formContext.mounted) {
                        await FormScope.of(formContext)?.refresh?.call();
                      }
                    },
                  ),
                );
              },
            ),
        ],
      );
    }

    List<StaticFormGroup> buildAllGroups() {
      if (reauthProviderNames().isNotEmpty) {
        return [
          buildReauthGroup(),
          if (!isNewlyActivated)
            StaticFormGroup(
              items: [
                FormButton(
                  key: 'archive',
                  skipValidation: true,
                  buildCommand: (_) => PromptToArchiveSource(
                    twistInstanceId: twistInstanceId,
                    name: name,
                  ),
                ),
              ],
            ),
        ];
      }
      return buildEditGroups();
    }

    Future<List<StaticFormGroup>> refresh() async {
      // Re-read the live plan so a just-completed upgrade clears the at-limit
      // gate on the save button when rebuilding.
      usage = _liveUsage(usage);
      teams = usage.teams;
      final refreshed = await Future.wait([
        TwistApi.getIntegrations(twistInstanceId),
        TwistConnection.getForInstance(twistInstanceUuid),
      ]);
      integrations = refreshed[0] as TwistIntegrations;
      connections = refreshed[1] as List<TwistConnectionRow>;
      return buildAllGroups();
    }

    return FormData(
      title: isNewlyActivated ? 'Set up $name' : name,
      onRefresh: refresh,
      refreshOn: SubscriptionService.instance.notifier,
      groups: buildAllGroups(),
      dismissable: dismissable,
    );
  }
}

/// Archive a source with confirmation.
class PromptToArchiveSource extends ShowForm {
  PromptToArchiveSource({required this.twistInstanceId, required this.name})
    : super(
        title: 'Archive',
        icon: PlotIcon.archived,
        form: (context) => _buildForm(twistInstanceId, name),
      );

  final String twistInstanceId;
  final String name;

  static Future<FormData> _buildForm(
    String twistInstanceId,
    String name,
  ) async {
    return FormData(
      title: 'Archive connection',
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              text:
                  'Archiving this connection will disconnect it and archive the threads it has created.',
            ),
            FormDivider(key: 'divider'),
            FormButton(
              key: 'archive',
              isPrimary: true,
              buildCommand: (_) => _ArchiveSourceCommand(twistInstanceId, name),
            ),
          ],
        ),
      ],
    );
  }
}

class _ArchiveSourceCommand extends Command {
  _ArchiveSourceCommand(this.twistInstanceId, this.name)
    : super(
        title: 'Archive connection',
        icon: PlotIcon.archived,
        eventObject: EventObject.twist,
        eventAction: EventAction.archived,
      );

  final String twistInstanceId;
  final String name;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await TwistApi.archiveAndRemoveTwist(twistInstanceId);

      // Update local database to immediately reflect the archive.
      // Try cache first, fall back to DB query if cache misses.
      final id = Uuid.fromString(twistInstanceId);
      var twist = TwistInstance.fromCache(id);
      twist ??=
          await (Store.get.select(TwistInstance.table)
                ..where((t) => t.id.equals(id.toBytes())))
              .getSingleOrNull()
              .then((row) => row == null ? null : TwistInstance(row));

      if (twist != null) {
        await Store.get.save(
          TwistInstance.table,
          twist.copyWith(
            archivedAt: Value(DateTime.now()),
            updatedAt: DateTime.now(),
          ),
          TwistInstancesBase(),
        );
      }

      return CommandMessage('Connection "$name" archived successfully');
    } catch (e, t) {
      log.warning('Failed to archive source', e, t);
      Tracker.captureException(e, t);
      return CommandMessage('Failed to archive connection', isError: true);
    }
  }
}

// ============================================================================
// Add Source
// ============================================================================

/// Shows a filterable list of available sources to add.
class AddSource extends ShowCommands {
  AddSource()
    : super(
        title: 'Add connection',
        icon: PlotIcon.save,
        commandsBuilder: (context) => _getSourceCommands(),
      );

  static Future<Commands> _getSourceCommands() async {
    final allTwists = await TwistApi.getAllTwists();
    final sourceTwists = allTwists.where((t) => t.isSource).toList();

    sourceTwists.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

    final commands = sourceTwists
        .map((twist) => AddSourceDetail(twist))
        .toList();

    return Commands(
      groups: [
        StaticCommandGroup(title: 'Available connections', commands: commands),
      ],
    );
  }
}

/// After an OAuth connect, decide whether to open the channel-setup
/// (EditSource) step on the still-draft instance.
///
/// OAuth connectors (those exposing [hasProviders]) defer channel selection to
/// a second step: the connection stays a draft until the user picks channels in
/// EditSource and saves (which activates the draft). No-provider connectors
/// finish inside the setup modal itself ([completedInSetupModal]), so there is
/// nothing more to open. A null [connectedDraftId] means the user backed out
/// before connecting, so there is no draft to set up.
bool shouldOpenChannelSetupAfterConnect({
  required String? connectedDraftId,
  required bool hasProviders,
  required bool completedInSetupModal,
}) => connectedDraftId != null && hasProviders && !completedInSetupModal;

/// Initial Label value for the setup modal. Prefers the OAuth-provided account
/// name (e.g. Unipile's `name` field for LinkedIn) over the stored
/// `account_label`, because the latter is often the generic "Personal" fallback
/// that backend activation seeds when no provider metadata is available — a
/// stale placeholder that should not beat the real account identity surfaced by
/// the integrations response.
String initialLabelForSource(
  TwistIntegrations integrations,
  List<TeamUsage> teams,
) {
  for (final account in integrations.accounts) {
    final name = account.name;
    if (name != null && name.isNotEmpty) return name;
  }
  final stored = integrations.accountLabel;
  if (stored != null && stored.isNotEmpty) return stored;
  final teamName = integrations.teamName;
  if (teamName != null && teamName.isNotEmpty) return teamName;
  return 'Personal';
}

/// Shows source description and branded auth button for setup.
class AddSourceDetail extends ShowForm {
  AddSourceDetail(this.twist, {this.dismissable = false})
    : super(
        title: twist.name,
        subtitle: twist.description,
        icon: PlotIcon.connection,
        form: (context) => _buildForm(context, twist, dismissable),
      );

  final Twist twist;

  /// When true, the form modal renders a close (X) in its header even when
  /// it's the only modal on the stack. Used by the onboarding flow, which
  /// opens AddSourceDetail with no parent modal to fall back to. Default:
  /// false — preserves the existing back-button-only header for callers
  /// that open AddSourceDetail from inside ManageConnections.
  final bool dismissable;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Create draft before opening form
    String? draftId;
    try {
      draftId = await TwistApi.createDraft(
        twistId: twist.id,
        twistEnvironment: twist.environment,
        name: twist.name,
      );
    } catch (e, t) {
      log.warning('Failed to create draft source', e, t);
      return CommandMessage(
        'Failed to set up connection. Please try again.',
        isError: true,
      );
    }

    _currentDraftId = draftId;
    lastConnectedDraftId = null;
    lastConnectedTeamId = null;

    // Re-run the form when a CommandRefresh is returned (e.g. after connecting
    // a no-provider connector — the form rebuilds to show channels).
    CommandReturn result = const CommandSkipped();
    while (context.mounted) {
      // ignore: use_build_context_synchronously — checked by while condition
      result = await super.run(context);
      if (result is! CommandRefresh) break;
    }

    // If the form was dismissed without activation, delete the draft
    if (_currentDraftId != null) {
      try {
        await TwistApi.deleteDraft(draftId);
      } catch (e, t) {
        log.warning('Failed to delete draft source', e, t);
      }
      _currentDraftId = null;
    }

    return result;
  }

  static String? _currentDraftId;

  /// Set after a successful OAuth connect. The instance is still a DRAFT at
  /// this point — ManageConnections (and the onboarding flows) read this to
  /// open the channel-setup (EditSource) step, which activates the draft on
  /// save and deletes it if the user abandons setup.
  static String? lastConnectedDraftId;

  /// The team (owner) resolved for [lastConnectedDraftId] from the OAuth
  /// account's email domain, or null for personal. EditSource uses it to
  /// default the team selector for the just-connected draft. Cleared by
  /// EditSource once consumed.
  static String? lastConnectedTeamId;

  /// True when the user finished setup (Label, channels, options, activate)
  /// inside the setup modal itself — i.e. activation went through
  /// `_ActivateNoProviderSource`. ManageConnections reads this to skip the
  /// follow-up EditSource modal, which would otherwise stack on top as a
  /// redundant second "Set up …" screen.
  static bool lastActivatedInSetupModal = false;

  /// Cached connect result from ConnectNoProviderCommand, used when the form
  /// rebuilds after CommandRefresh so we don't depend on getAccountName
  /// succeeding again in GET /integrations.
  static TwistConnectResult? _lastConnectResult;

  static void clearDraft() {
    _currentDraftId = null;
    _lastConnectResult = null;
  }

  static Future<FormData> _buildForm(
    BuildContext context,
    Twist twist,
    bool dismissable,
  ) async {
    final draftId = _currentDraftId;
    if (draftId == null) {
      return FormData(
        title: twist.name,
        dismissable: dismissable,
        groups: [
          StaticFormGroup(
            items: [
              FormInfo(
                key: 'error',
                text: 'Failed to create draft connection.',
              ),
            ],
          ),
        ],
      );
    }

    // Pre-fetch integrations and the freshest usage. Usage comes from the
    // SubscriptionService (the app-wide source of truth, kept current on
    // websocket broadcast and app refocus) so the upgrade/at-limit gates below
    // rebuild reactively when the plan changes — see the `refreshOn` wiring on
    // the returned FormData. `usage`/`teams` are mutable so the onRefresh
    // closure can re-read the live snapshot.
    final results = await Future.wait([
      TwistApi.getIntegrations(draftId),
      _freshUsage(),
    ]);
    var integrations = results[0] as TwistIntegrations;
    var usage = results[1] as UsageData;
    var teams = usage.teams;

    // If we have a cached connect result with an account name but the API
    // didn't return accounts (getAccountName may have failed), inject it.
    final cachedResult = _lastConnectResult;
    if (cachedResult?.accountName != null && integrations.accounts.isEmpty) {
      integrations = TwistIntegrations(
        providers: integrations.providers,
        accounts: [
          TwistAccount(
            provider: AuthProvider.other,
            actorId: draftId,
            name: cachedResult!.accountName,
          ),
        ],
        channels: integrations.channels,
        optionsSchema: integrations.optionsSchema,
        optionsConfig: integrations.optionsConfig,
        teamDomains: integrations.teamDomains,
      );
    }

    // Track enabled scope groups per provider (for providers with optional scopes)
    final scopeGroupSelections = <String, Set<String>>{};
    for (final provider in integrations.providers) {
      if (provider.optionalScopes != null) {
        scopeGroupSelections[provider.provider.name] = {
          for (final group in provider.optionalScopes!)
            if (group.defaultEnabled) group.id,
        };
      }
    }

    // Build option form items (for connectors using API key auth)
    final hasOptions =
        twist.optionsSchema != null && twist.optionsSchema!.isNotEmpty;
    final optionItems = hasOptions
        ? TwistOptionItems(options: twist.optionsSchema!)
        : null;

    // State for no-provider connector channel selection (captured by closures)
    // ignore: prefer_final_locals
    var noProviderChanges = const IntegrationChanges();
    final noProviderChannelController = FormChannelListController();

    // For OAuth connectors, suppress the Personal/team selector until the user
    // has authenticated an account; we can then default to the matching team.
    bool isOAuthPreAuth(TwistIntegrations current) =>
        current.providers.isNotEmpty && current.accounts.isEmpty;

    String defaultTeamFor(TwistIntegrations current) {
      final domains = current.teamDomains;
      if (domains != null) {
        for (final account in current.accounts) {
          final email = account.email;
          if (email == null) continue;
          final atIdx = email.lastIndexOf('@');
          if (atIdx < 0) continue;
          final domain = email.substring(atIdx + 1).toLowerCase();
          for (final entry in domains.entries) {
            if (entry.value.any((d) => d.toLowerCase() == domain)) {
              final teamId = entry.key.toString();
              if (teams.any((t) => t.id == teamId)) return teamId;
            }
          }
        }
      }
      // No domain match: prefer a team over personal so connections count
      // against team quota by default. User can switch in the selector.
      if (teams.isNotEmpty) return teams.first.id;
      return 'personal';
    }

    FormItem? buildTeamSelect(TwistIntegrations current) {
      if (teams.isEmpty) return null;
      if (isOAuthPreAuth(current)) return null;
      return FormSelect<String>(
        key: 'team_id',
        label: 'Team',
        initialValue: defaultTeamFor(current),
        items: (search) async => ['personal', ...teams.map((t) => t.id)],
        titleBuilder: (id) => id == 'personal'
            ? 'Personal'
            : teams.firstWhere((t) => t.id == id).name,
      );
    }

    Future<List<StaticFormGroup>> buildGroups() async {
      // Re-read the live plan so a just-completed upgrade swaps the upgrade
      // button for the auth/connect button on rebuild.
      usage = _liveUsage(usage);
      teams = usage.teams;
      // Re-fetch integrations on refresh
      var refreshed = await TwistApi.getIntegrations(draftId);
      final cached = _lastConnectResult;
      if (cached?.accountName != null && refreshed.accounts.isEmpty) {
        refreshed = TwistIntegrations(
          providers: refreshed.providers,
          accounts: [
            TwistAccount(
              provider: AuthProvider.other,
              actorId: draftId,
              name: cached!.accountName,
            ),
          ],
          channels: refreshed.channels,
          optionsSchema: refreshed.optionsSchema,
          optionsConfig: refreshed.optionsConfig,
          teamDomains: refreshed.teamDomains,
        );
      }

      final refreshChannelController = FormChannelListController();
      // ignore: prefer_final_locals
      var refreshChanges = const IntegrationChanges();

      final refreshedDefault = defaultTeamFor(refreshed);
      // Same hosted-auth-already-authed guard as the initial render: when a
      // hosted-auth draft already has an authenticated account, fall through
      // to the standard Label / Team / channels / options layout instead of
      // re-rendering the auth button.
      final refreshedHostedHasAccount =
          refreshed.providers.isNotEmpty && refreshed.accounts.isNotEmpty;
      final refreshedInitialLabel = initialLabelForSource(refreshed, teams);
      return [
        StaticFormGroup(
          items: [
            if (twist.description != null)
              FormInfo(key: 'description', text: twist.description!),
            if (refreshedHostedHasAccount) ...[
              ..._buildStandardSourceItems(
                twistInstanceId: draftId,
                sourceName: twist.name,
                logoUrl: twist.logoUrl,
                logoUrlDark: twist.logoUrlDark,
                integrations: refreshed,
                teams: teams,
                initialTeamId: refreshedDefault,
                initialLabel: refreshedInitialLabel,
                channelListController: refreshChannelController,
                onChannelChanges: (changes) {
                  refreshChanges = changes;
                },
                channelsValidator: () =>
                    refreshChanges.selectedChannels.isNotEmpty,
                setupMode: true,
                isAccountBased: true,
                optionItems: optionItems,
              ),
              FormButton(
                key: 'add_connection',
                isPrimary: true,
                buildCommand: (values) {
                  final owner = values['team_id'] as String? ?? 'personal';
                  final label =
                      (values['account_label'] as String?)?.trim() ?? '';
                  return _ActivateNoProviderSource(
                    draftId: draftId,
                    twistName: twist.name,
                    teamId: owner == 'personal' ? null : owner,
                    getChanges: () => refreshChanges,
                    accountLabel: label.isEmpty ? null : label,
                    connectorCategory: twist.category,
                    isPremium: twist.premium,
                    connectContext: dismissable ? 'onboarding' : 'settings',
                  );
                },
              ),
            ] else ...[
              if (buildTeamSelect(refreshed) != null)
                buildTeamSelect(refreshed)!,
              ...refreshed.providers.map((provider) {
                final initialOwner = refreshedDefault;
                // Premium gate (Free/Core: blocked; Pro: at-limit if used;
                // Team: at-limit when remaining pool < 3). Falls through to
                // the regular at-limit logic when premium is allowed.
                final premiumGate = teams.isEmpty
                    ? _premiumGateCommand(
                        usage: usage,
                        owner: initialOwner,
                        isPremium: twist.premium,
                      )
                    : null;
                if (premiumGate != null) {
                  return FormButton(
                    key: 'upgrade_premium_${provider.provider.name}',
                    isPrimary: true,
                    buildCommand: (_) => premiumGate,
                  );
                }
                // Gate preemptively only when the user has no team to fall
                // back to. When teams exist, let them authenticate — the
                // save/connect path checks the selected team's limit.
                final initialAtLimit =
                    teams.isEmpty && usage.personal.connections.isAtLimit;

                if (initialAtLimit) {
                  return FormButton(
                    key: 'upgrade_${provider.provider.name}',
                    isPrimary: true,
                    buildCommand: (_) => _connectionAtLimitCommand(),
                  );
                }

                return FormInfo(
                  key: 'auth_${provider.provider.name}',
                  divider: false,
                  builder: (formContext) {
                    return Padding(
                      // Match the xl horizontal padding every other form item
                      // (and the description above) uses, so the bullets,
                      // toggles, and auth button left-align with the rest.
                      padding: EdgeInsets.only(
                        left: formContext.theme.spacing.xl,
                        right: formContext.theme.spacing.xl,
                        bottom: formContext.theme.spacing.lg,
                      ),
                      child: _AuthWithScopeToggles(
                        provider: provider,
                        twistInstanceId: draftId,
                        initialEnabledGroups:
                            scopeGroupSelections[provider.provider.name],
                        onScopeGroupsChanged: (groups) {
                          scopeGroupSelections[provider.provider.name] = groups;
                        },
                        onSuccess: () async {
                          await _connectedAfterOAuth(
                            formContext,
                            draftId,
                            twist.name,
                            teams,
                            fallbackOwner: initialOwner,
                          );
                        },
                      ),
                    );
                  },
                );
              }),
              if (optionItems != null &&
                  (refreshed.providers.isNotEmpty || refreshed.isEmpty)) ...[
                ?_accessBulletsItem(refreshed.access),
                ...optionItems.items,
              ],
              if (refreshed.providers.isEmpty &&
                  optionItems != null &&
                  refreshed.isEmpty)
                FormButton(
                  key: 'connect',
                  isPrimary: true,
                  buildCommand: (values) {
                    final owner = values['team_id'] as String? ?? 'personal';
                    final live = _liveUsage(usage);
                    final premiumGate = _premiumGateCommand(
                      usage: live,
                      owner: owner,
                      isPremium: twist.premium,
                    );
                    if (premiumGate != null) return premiumGate;
                    final team = live.teams.firstWhereOrNull(
                      (t) => t.id == owner,
                    );
                    final atLimit = team != null
                        ? team.connections.isAtLimit
                        : live.personal.connections.isAtLimit;

                    if (atLimit) {
                      return _connectionAtLimitCommand();
                    }

                    return ConnectNoProviderCommand(
                      twistInstanceId: draftId,
                      optionItems: optionItems,
                      teamId: owner == 'personal' ? null : owner,
                    );
                  },
                ),
              if (refreshed.providers.isEmpty && !refreshed.isEmpty) ...[
                FormChannelList(
                  key: 'channels',
                  controller: refreshChannelController,
                  validator: () => refreshChanges.selectedChannels.isNotEmpty,
                  builder: (context) => SetupSourceWidget(
                    twistInstanceId: draftId,
                    setupMode: true,
                    isAccountBased: true,
                    sourceName: twist.name,
                    logoUrl: twist.logoUrl,
                    logoUrlDark: twist.logoUrlDark,
                    initialData: refreshed,
                    channelListController: refreshChannelController,
                    onChanged: (changes) {
                      refreshChanges = changes;
                    },
                  ),
                ),
                FormButton(
                  key: 'add_connection',
                  isPrimary: true,
                  buildCommand: (values) {
                    final owner = values['team_id'] as String? ?? 'personal';
                    return _ActivateNoProviderSource(
                      draftId: draftId,
                      twistName: twist.name,
                      teamId: owner == 'personal' ? null : owner,
                      getChanges: () => refreshChanges,
                      connectorCategory: twist.category,
                      isPremium: twist.premium,
                      connectContext: dismissable ? 'onboarding' : 'settings',
                    );
                  },
                ),
              ],
            ],
          ],
        ),
      ];
    }

    // When a hosted-auth draft is reopened and already has an authenticated
    // account (the OAuth callback persisted the token in DO storage during a
    // prior session, or the form is rebuilding after onSuccess), skip the
    // auth button and render the standard setup layout — Label, Team,
    // account, options — so the user finishes setup in one place rather
    // than re-triggering the hosted-auth flow.
    final hostedHasAccount =
        integrations.providers.isNotEmpty && integrations.accounts.isNotEmpty;
    final initialLabel = initialLabelForSource(integrations, teams);

    return FormData(
      title: 'Set up ${twist.name}',
      onRefresh: buildGroups,
      // Rebuild the moment the plan changes (e.g. after a browser upgrade with
      // no child modal to pop) so the upgrade button becomes the auth button.
      refreshOn: SubscriptionService.instance.notifier,
      dismissable: dismissable,
      groups: [
        StaticFormGroup(
          items: [
            if (twist.description != null)
              FormInfo(key: 'description', text: twist.description!),
            if (hostedHasAccount) ...[
              ..._buildStandardSourceItems(
                twistInstanceId: draftId,
                sourceName: twist.name,
                logoUrl: twist.logoUrl,
                logoUrlDark: twist.logoUrlDark,
                integrations: integrations,
                teams: teams,
                initialTeamId: defaultTeamFor(integrations),
                initialLabel: initialLabel,
                channelListController: noProviderChannelController,
                onChannelChanges: (changes) {
                  noProviderChanges = changes;
                },
                channelsValidator: () =>
                    noProviderChanges.selectedChannels.isNotEmpty,
                setupMode: true,
                isAccountBased: true,
                optionItems: optionItems,
              ),
              FormButton(
                key: 'add_connection',
                isPrimary: true,
                buildCommand: (values) {
                  final owner = values['team_id'] as String? ?? 'personal';
                  final label =
                      (values['account_label'] as String?)?.trim() ?? '';
                  return _ActivateNoProviderSource(
                    draftId: draftId,
                    twistName: twist.name,
                    teamId: owner == 'personal' ? null : owner,
                    getChanges: () => noProviderChanges,
                    accountLabel: label.isEmpty ? null : label,
                    connectorCategory: twist.category,
                    isPremium: twist.premium,
                    connectContext: dismissable ? 'onboarding' : 'settings',
                  );
                },
              ),
            ] else ...[
              if (buildTeamSelect(integrations) != null)
                buildTeamSelect(integrations)!,
              ...integrations.providers.map((provider) {
                final initialOwner = defaultTeamFor(integrations);
                // Premium gate (see twin block above for the variant flow).
                final premiumGate = teams.isEmpty
                    ? _premiumGateCommand(
                        usage: usage,
                        owner: initialOwner,
                        isPremium: twist.premium,
                      )
                    : null;
                if (premiumGate != null) {
                  return FormButton(
                    key: 'upgrade_premium_${provider.provider.name}',
                    isPrimary: true,
                    buildCommand: (_) => premiumGate,
                  );
                }
                // Gate preemptively only when the user has no team to fall
                // back to. When teams exist, let them authenticate — the
                // save/connect path checks the selected team's limit.
                final initialAtLimit =
                    teams.isEmpty && usage.personal.connections.isAtLimit;

                if (initialAtLimit) {
                  return FormButton(
                    key: 'upgrade_${provider.provider.name}',
                    isPrimary: true,
                    buildCommand: (_) => _connectionAtLimitCommand(),
                  );
                }

                return FormInfo(
                  key: 'auth_${provider.provider.name}',
                  divider: false,
                  builder: (formContext) {
                    return Padding(
                      // Match the xl horizontal padding every other form item
                      // (and the description above) uses, so the bullets,
                      // toggles, and auth button left-align with the rest.
                      padding: EdgeInsets.only(
                        left: formContext.theme.spacing.xl,
                        right: formContext.theme.spacing.xl,
                        bottom: formContext.theme.spacing.lg,
                      ),
                      child: _AuthWithScopeToggles(
                        provider: provider,
                        twistInstanceId: draftId,
                        initialEnabledGroups:
                            scopeGroupSelections[provider.provider.name],
                        onScopeGroupsChanged: (groups) {
                          scopeGroupSelections[provider.provider.name] = groups;
                        },
                        onSuccess: () async {
                          await _connectedAfterOAuth(
                            formContext,
                            draftId,
                            twist.name,
                            teams,
                            fallbackOwner: initialOwner,
                          );
                        },
                      ),
                    );
                  },
                );
              }),
              if (optionItems != null &&
                  (integrations.providers.isNotEmpty ||
                      integrations.isEmpty)) ...[
                ?_accessBulletsItem(integrations.access),
                ...optionItems.items,
              ],
              if (integrations.providers.isEmpty &&
                  optionItems != null &&
                  integrations.isEmpty)
                // Not yet connected: show Connect button
                FormButton(
                  key: 'connect',
                  isPrimary: true,
                  buildCommand: (values) {
                    final owner = values['team_id'] as String? ?? 'personal';
                    final live = _liveUsage(usage);
                    final premiumGate = _premiumGateCommand(
                      usage: live,
                      owner: owner,
                      isPremium: twist.premium,
                    );
                    if (premiumGate != null) return premiumGate;
                    final team = live.teams.firstWhereOrNull(
                      (t) => t.id == owner,
                    );
                    final atLimit = team != null
                        ? team.connections.isAtLimit
                        : live.personal.connections.isAtLimit;

                    if (atLimit) {
                      return _connectionAtLimitCommand();
                    }

                    return ConnectNoProviderCommand(
                      twistInstanceId: draftId,
                      optionItems: optionItems,
                      teamId: owner == 'personal' ? null : owner,
                    );
                  },
                ),
              if (integrations.providers.isEmpty && !integrations.isEmpty) ...[
                // Already connected: show channels + Add connection
                FormChannelList(
                  key: 'channels',
                  controller: noProviderChannelController,
                  validator: () =>
                      noProviderChanges.selectedChannels.isNotEmpty,
                  builder: (context) => SetupSourceWidget(
                    twistInstanceId: draftId,
                    setupMode: true,
                    isAccountBased: true,
                    sourceName: twist.name,
                    logoUrl: twist.logoUrl,
                    logoUrlDark: twist.logoUrlDark,
                    initialData: integrations,
                    channelListController: noProviderChannelController,
                    onChanged: (changes) {
                      noProviderChanges = changes;
                    },
                  ),
                ),
                FormButton(
                  key: 'add_connection',
                  isPrimary: true,
                  buildCommand: (values) {
                    final owner = values['team_id'] as String? ?? 'personal';
                    return _ActivateNoProviderSource(
                      draftId: draftId,
                      twistName: twist.name,
                      teamId: owner == 'personal' ? null : owner,
                      getChanges: () => noProviderChanges,
                      connectorCategory: twist.category,
                      isPremium: twist.premium,
                      connectContext: dismissable ? 'onboarding' : 'settings',
                    );
                  },
                ),
              ],
            ],
          ],
        ),
      ],
    );
  }

  /// After a successful OAuth, hand the still-DRAFT instance off to the
  /// channel-setup step (EditSource) without activating it. We re-fetch
  /// integrations only to default the connection's team based on the
  /// authenticated account's email domain; if the form has a visible team
  /// selector (post-auth state from a previous flow), its value wins. The
  /// draft is activated later, in EditSource's save, once the user has picked
  /// channels — and deleted if they abandon setup. This keeps `draft` meaning
  /// "uncommitted setup" so an abandoned OAuth leaves no orphaned connection.
  static Future<void> _connectedAfterOAuth(
    BuildContext context,
    String draftId,
    String name,
    List<TeamUsage> teams, {
    required String fallbackOwner,
  }) async {
    String owner = fallbackOwner;
    try {
      final refreshed = await TwistApi.getIntegrations(draftId);
      final domains = refreshed.teamDomains;
      if (domains != null) {
        for (final account in refreshed.accounts) {
          final email = account.email;
          if (email == null) continue;
          final atIdx = email.lastIndexOf('@');
          if (atIdx < 0) continue;
          final domain = email.substring(atIdx + 1).toLowerCase();
          String? matched;
          for (final entry in domains.entries) {
            if (entry.value.any((d) => d.toLowerCase() == domain)) {
              final teamId = entry.key.toString();
              if (teams.any((t) => t.id == teamId)) {
                matched = teamId;
                break;
              }
            }
          }
          if (matched != null) {
            owner = matched;
            break;
          }
        }
      }
    } catch (e, t) {
      log.warning('Failed to refresh integrations after OAuth', e, t);
    }

    if (context.mounted) {
      final values = FormScope.of(context)?.values ?? {};
      final selected = values['team_id'] as String?;
      if (selected != null) owner = selected;
    }

    // Record the connected draft + its default team so the caller opens
    // EditSource on it. Releasing our cleanup claim (clearDraft) transfers
    // ownership of the draft to EditSource, which now deletes it on abandon —
    // otherwise AddSourceDetail.run() would delete it the moment this modal
    // pops, before channel setup opens.
    lastConnectedDraftId = draftId;
    lastConnectedTeamId = owner == 'personal' ? null : owner;
    clearDraft();

    // Start fetching integrations for the upcoming EditSource in parallel with
    // the modal-pop animation, so the next modal can open immediately.
    EditSource.preloadIntegrations(draftId);

    if (context.mounted) {
      Modal.pop<CommandReturn>(context, Value(const CommandDone()));
    }
  }
}

// ============================================================================
// Manage Twists (non-source only)
// ============================================================================

/// Returns true if [twist] is a single-instance twist that is already active
/// in every scope available to the user (personal + all teams), making it
/// unavailable for additional installation.
bool _isFullyInstalled(
  Twist twist,
  List<TwistInstance> instances,
  List<TeamUsage> teams,
) {
  if (twist.multipleInstances) return false;

  // Check personal scope
  final inPersonal = instances.any(
    (i) =>
        i.twistId.toString() == twist.id &&
        i.teamId == null &&
        i.archivedAt == null,
  );
  if (!inPersonal) return false;

  // Check all team scopes
  for (final team in teams) {
    final inTeam = instances.any(
      (i) =>
          i.twistId.toString() == twist.id &&
          i.teamId?.toString() == team.id &&
          i.archivedAt == null,
    );
    if (!inTeam) return false;
  }

  return true;
}

/// Returns the list of scope IDs where [twist] can still be installed.
/// For multi-instance twists, returns all scopes (personal + all teams).
/// For single-instance twists, returns only scopes without an active instance.
List<String> _getAvailableScopes(
  Twist twist,
  List<TwistInstance> instances,
  List<TeamUsage> teams,
) {
  if (twist.multipleInstances) {
    return ['personal', ...teams.map((t) => t.id)];
  }

  final scopes = <String>[];

  final inPersonal = instances.any(
    (i) =>
        i.twistId.toString() == twist.id &&
        i.teamId == null &&
        i.archivedAt == null,
  );
  if (!inPersonal) scopes.add('personal');

  for (final team in teams) {
    final inTeam = instances.any(
      (i) =>
          i.twistId.toString() == twist.id &&
          i.teamId?.toString() == team.id &&
          i.archivedAt == null,
    );
    if (!inTeam) scopes.add(team.id);
  }

  return scopes;
}

class ManageTwists extends ShowCommands {
  ManageTwists([Priority? priority])
    : super(
        title: 'Twists',
        description: 'Add workflows and automations to your focuses.',
        icon: PlotIcon.twist,
        commandsBuilder: (context) => _getTwistCommands(priority),
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      return await super.run(context);
    } on ApiException catch (e, t) {
      log.warning('Failed to load twists', e, t);
      return const CommandMessage(
        'Could not connect to Plot servers.',
        isError: true,
      );
    } on NetworkException catch (e, t) {
      log.warning('Failed to load twists', e, t);
      return const CommandMessage(
        'Could not connect to Plot servers.',
        isError: true,
      );
    }
  }

  static Future<Commands> _getTwistCommands(Priority? priority) async {
    // Twists are workspace-level; priority arg is retained for route context
    // but is no longer used to filter which twists are shown.
    final results = await Future.wait([
      TwistInstance.get(),
      TwistApi.getAllTwists(),
    ]);
    final twistInstances = results[0] as List<TwistInstance>;
    final allTwists = results[1] as List<Twist>;

    // Fetch usage to check twist limits
    UsageData? usage;
    try {
      usage = await UpgradeApi.getUsage();
    } catch (_) {}
    // Filter to non-sources only
    final twistOnlyTwistInstances = twistInstances
        .where((pt) => !pt.isSource)
        .toList();
    final twistOnlyAvailable = allTwists.where((t) => !t.isSource).toList();

    final teams = usage?.teams ?? [];
    final editCommands = twistOnlyTwistInstances.map((twist) {
      final teamName = twist.teamId != null
          ? teams.firstWhereOrNull((t) => t.id == twist.teamId.toString())?.name
          : null;
      return EditTwist(
        twist,
        displayName: twist.displayName(
          allInstances: twistOnlyTwistInstances,
          teamName: teamName,
        ),
      );
    }).toList();

    // Sort active twists by name, then environment
    editCommands.sort((a, b) {
      // Primary: alphabetical by name (case-insensitive)
      final nameComparison = a.twistInstance.name.toLowerCase().compareTo(
        b.twistInstance.name.toLowerCase(),
      );
      if (nameComparison != 0) return nameComparison;

      // Secondary: environment (public, review, private, personal)
      return _compareEnvironment(
        a.twistInstance.twistEnvironment,
        b.twistInstance.twistEnvironment,
      );
    });
    final addCommands = twistOnlyAvailable
        .where(
          (twist) => !_isFullyInstalled(twist, twistOnlyTwistInstances, teams),
        )
        .map((twist) => ShowTwistInfo(twist))
        .toList();

    // Sort available twists by name, then environment
    addCommands.sort((a, b) {
      // Primary: alphabetical by name (case-insensitive)
      final nameComparison = a.twist.name.toLowerCase().compareTo(
        b.twist.name.toLowerCase(),
      );
      if (nameComparison != 0) return nameComparison;

      // Secondary: environment (public, review, private, personal)
      return _compareEnvironment(a.twist.environment, b.twist.environment);
    });

    final activeTitle = usage != null
        ? 'Active twists ${_usageSuffix(usage, _ResourceType.twists)}'
        : 'Active twists';

    return Commands(
      groups: [
        StaticCommandGroup(title: activeTitle, commands: editCommands.toList()),
        StaticCommandGroup(title: 'Available twists', commands: addCommands),
      ],
    );
  }
}

// ============================================================================
// Edit Twist (existing twist)
// ============================================================================

class EditTwist extends ShowForm {
  EditTwist(this.twistInstance, {String? displayName})
    : super(
        title: displayName ?? twistInstance.name,
        icon: PlotIcon.settings,
        form: (context) => _buildForm(context, twistInstance),
      );

  final TwistInstance twistInstance;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) {
    final isDark = context.colour.brightness == Brightness.dark;
    final url = isDark && twistInstance.logoUrlDark != null
        ? twistInstance.logoUrlDark
        : twistInstance.logoUrl;
    if (url != null) {
      return LogoImage(url: url, size: context.theme.iconSizes.base);
    }
    return null;
  }

  static Future<FormData> _buildForm(
    BuildContext context,
    TwistInstance twistInstance,
  ) async {
    try {
      // Fetch metadata and usage in parallel
      final results = await Future.wait([
        TwistApi.getAllTwists(),
        ManageConnections._dataCache?.usage != null
            ? Future.value(ManageConnections._dataCache!.usage!)
            : UpgradeApi.getUsage(),
        TwistInstance.get(),
      ]);
      final allTwists = results[0] as List<Twist>;
      final usage = results[1] as UsageData;
      final twistInstances = results[2] as List<TwistInstance>;
      final teams = usage.teams;

      final matchingTwist = allTwists.firstWhere(
        (a) => a.id == twistInstance.twistId.toString(),
        orElse: () => throw Exception('Twist not found'),
      );

      // Build option form items
      final hasOptions =
          matchingTwist.optionsSchema != null &&
          matchingTwist.optionsSchema!.isNotEmpty;
      final optionItems = hasOptions
          ? TwistOptionItems(
              options: matchingTwist.optionsSchema!,
              initialConfig: twistInstance.config,
            )
          : null;

      // Check if twist has link permission (and is not a source)
      final hasLinkPermission =
          !matchingTwist.isSource &&
          matchingTwist.permissions != null &&
          matchingTwist.permissions!.hasPermission(
            'plot',
            'link',
            PermissionFlag.read,
          );

      // Track link channel changes
      var linkChannelSelection = const LinkChannelSelection();
      final linkChannelListController = FormChannelListController();

      final initialTeamId = twistInstance.teamId != null
          ? twistInstance.teamId.toString()
          : 'personal';

      return FormData(
        title: 'Edit ${twistInstance.name}',
        groups: [
          StaticFormGroup(
            items: [
              // Name is hidden and not editable for single-instance twists
              if (matchingTwist.multipleInstances)
                FormTextInput(
                  key: 'name',
                  label: 'Name',
                  initialValue: twistInstance.name,
                  required: true,
                ),
              if (teams.isNotEmpty)
                FormSelect<String>(
                  key: 'team_id',
                  label: 'Team',
                  initialValue: initialTeamId,
                  items: (search) async {
                    if (!matchingTwist.multipleInstances) {
                      // For single-instance twists, only offer the current scope
                      // plus any unoccupied scopes
                      final otherInstances = twistInstances
                          .where((i) => i.id != twistInstance.id)
                          .toList();
                      return [
                        initialTeamId,
                        ..._getAvailableScopes(
                          matchingTwist,
                          otherInstances,
                          teams,
                        ).where((s) => s != initialTeamId),
                      ];
                    }
                    return ['personal', ...teams.map((t) => t.id)];
                  },
                  titleBuilder: (id) => id == 'personal'
                      ? 'Personal'
                      : teams.firstWhere((t) => t.id == id).name,
                ),
              if (hasLinkPermission)
                FormChannelList(
                  key: 'link_channels',
                  controller: linkChannelListController,
                  builder: (context) => SetupLinkChannelsWidget(
                    twistInstanceId: twistInstance.id.toString(),
                    channelListController: linkChannelListController,
                    onChanged: (selection) {
                      linkChannelSelection = selection;
                    },
                  ),
                ),
            ],
          ),
          if (optionItems != null) StaticFormGroup(items: optionItems.items),
          StaticFormGroup(
            items: [
              FormButton(
                key: 'save',
                isPrimary: true,
                buildCommand: (values) {
                  final owner = values['team_id'] as String? ?? initialTeamId;

                  // Check twist limit if owner changes (for non-sources)
                  if (owner != initialTeamId && !matchingTwist.isSource) {
                    // Check personal limits against the live plan so a
                    // just-completed upgrade isn't blocked by a stale snapshot.
                    if (owner == 'personal' &&
                        _liveUsage(usage).personal.twists.isAtLimit) {
                      return _twistAtLimitCommand();
                    }
                    // Note: team twist limits are not yet tracked in UsageData (UI side),
                    // but backend will enforce them (0 for free team plan).
                  }

                  final name = matchingTwist.multipleInstances
                      ? (values['name'] as String? ?? twistInstance.name)
                      : twistInstance.name;
                  return SaveTwistSettings(
                    twistInstance: twistInstance,
                    name: name,
                    config: optionItems?.values,
                    linkChannels: hasLinkPermission
                        ? linkChannelSelection.entries
                        : null,
                    teamId: owner == 'personal' ? null : owner,
                  );
                },
              ),
              FormButton(
                key: 'details',
                buildCommand: (_) => ShowTwistDetails(matchingTwist),
              ),
              if (!twistInstance.isBuiltin)
                FormButton(
                  key: 'archive',
                  destructive: true,
                  buildCommand: (_) => PromptToArchiveTwist(twistInstance),
                ),
            ],
          ),
        ],
      );
    } catch (e, t) {
      log.warning('Error loading twist details', e, t);
      // Fallback to simple form without details
      return FormData(
        title: 'Edit ${twistInstance.name}',
        groups: [
          StaticFormGroup(
            items: [
              FormTextInput(
                key: 'name',
                label: 'Name',
                initialValue: twistInstance.name,
                required: true,
              ),
              FormButton(
                key: 'save',
                isPrimary: true,
                buildCommand: (values) {
                  final name = values['name'] as String;
                  return EditTwistName(twistInstance, name: name);
                },
              ),
              if (!twistInstance.isBuiltin)
                FormButton(
                  key: 'archive',
                  destructive: true,
                  buildCommand: (_) => PromptToArchiveTwist(twistInstance),
                ),
            ],
          ),
        ],
      );
    }
  }
}

// ============================================================================
// Show Twist Info (details only) + Setup Twist (add flow)
// ============================================================================

class ShowTwistDetails extends ShowForm {
  ShowTwistDetails(this.twist)
    : super(
        title: 'View twist details',
        icon: PlotIcon.twist,
        form: (context) => _buildForm(twist),
      );

  final Twist twist;

  static Future<FormData> _buildForm(Twist twist) async {
    // Only fetch keys info for twists that use AI
    bool? hasAiKeys;
    if (twist.permissions?.forDomain('ai') != null) {
      final aiKeys = await UpgradeApi.getAiKeys();
      hasAiKeys = aiKeys.isNotEmpty;
    }

    return FormData(
      title: twist.name,
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'details',
              divider: false,
              builder: (context) =>
                  TwistDetails(twist: twist, hasAiKeys: hasAiKeys),
            ),
          ],
        ),
      ],
    );
  }
}

/// Shows twist details (description, author, permissions) with an "Add Twist" button.
class ShowTwistInfo extends ShowForm {
  ShowTwistInfo(this.twist)
    : super(
        title: twist.name,
        subtitle: twist.description,
        icon: PlotIcon.twist,
        form: (context) => _buildForm(context, twist),
      );

  final Twist twist;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) {
    final isDark = context.colour.brightness == Brightness.dark;
    final url = isDark && twist.logoUrlDark != null
        ? twist.logoUrlDark
        : twist.logoUrl;
    if (url != null) {
      return LogoImage(url: url, size: context.theme.iconSizes.base);
    }
    return null;
  }

  @override
  Widget? buildBody(BuildContext context) {
    if (twist.environment == 'public') return null;
    final theme = context.theme;
    return Row(
      children: [
        Text(
          twist.name,
          overflow: TextOverflow.ellipsis,
          style: theme.typography.md.copyWith(color: theme.colors.foreground),
        ),
        const SizedBox(width: 6),
        _EnvironmentBadge(environment: twist.environment),
        if (twist.description != null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              twist.description!,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.md.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
          ),
        ],
      ],
    );
  }

  static Future<FormData> _buildForm(BuildContext context, Twist twist) async {
    // Fetch AI keys and usage in parallel. We no longer gate twists on plan
    // tier — AI-required twists work for any user who has their own API
    // keys, regardless of subscription state. Plan-only AI inclusion is
    // returning in a future Premium AI add-on.
    final results = await Future.wait([
      UpgradeApi.getAiKeys(),
      _freshUsage().then<UsageData?>((r) => r).catchError((_) => null),
    ]);
    final aiKeys = results[0] as List<String>;
    final hasAiKeys = aiKeys.isNotEmpty;

    // Block AI-required twists when the user has no API keys.
    final blocked = twist.aiRequired && !hasAiKeys;

    List<StaticFormGroup> buildGroups() {
      // Prefer the live plan so the "Upgrade to add more twists" button flips
      // back to the normal add button the moment the user upgrades.
      final usage = SubscriptionService.instance.usage ?? results[1] as UsageData?;
      // Only gate entry when the user has no team to fall back to. If they
      // have teams, let them reach the setup form and pick a scope — the
      // save-time check in SetupTwist will gate against the chosen owner.
      final atTwistLimit = usage != null &&
          usage.teams.isEmpty &&
          usage.personal.twists.isAtLimit;
      return [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              divider: true,
              builder: (context) =>
                  TwistDetails(twist: twist, hasAiKeys: hasAiKeys),
            ),
            if (!blocked)
              FormButton(
                key: 'add',
                isPrimary: true,
                buildCommand: (_) =>
                    atTwistLimit ? _twistAtLimitCommand() : SetupTwist(twist),
              ),
          ],
        ),
      ];
    }

    return FormData(
      title: twist.name,
      onRefresh: () async => buildGroups(),
      refreshOn: SubscriptionService.instance.notifier,
      groups: buildGroups(),
    );
  }
}

// ============================================================================
// Setup Twist (add flow with draft)
// ============================================================================

/// Opens the setup modal with priority selector, name, integrations, and channels.
/// Creates a draft twist for the auth flow, then activates it on submit.
class SetupTwist extends ShowForm {
  SetupTwist(this.twist)
    : super(
        title: 'Add twist',
        icon: PlotIcon.add,
        form: (context) => _buildForm(context, twist),
      );

  final Twist twist;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Create draft before opening form
    String? draftId;
    try {
      draftId = await TwistApi.createDraft(
        twistId: twist.id,
        twistEnvironment: twist.environment,
        name: twist.name,
      );
    } catch (e, t) {
      log.warning('Failed to create draft twist', e, t);
      return CommandMessage(
        'Failed to set up twist. Please try again.',
        isError: true,
      );
    }

    // Store draftId for the form builder via a static variable
    _currentDraftId = draftId;

    if (!context.mounted) return const CommandSkipped();
    final result = await super.run(context);

    // If the form was dismissed without activation, delete the draft
    if (_currentDraftId != null) {
      try {
        await TwistApi.deleteDraft(draftId);
      } catch (e, t) {
        log.warning('Failed to delete draft twist', e, t);
      }
      _currentDraftId = null;
    }

    return result;
  }

  /// Current draft ID, set before opening the form.
  static String? _currentDraftId;

  /// Called by ActivateDraftCommand to clear the draft ID after successful activation.
  static void clearDraft() {
    _currentDraftId = null;
  }

  static Future<FormData> _buildForm(BuildContext context, Twist twist) async {
    final draftId = _currentDraftId;
    if (draftId == null) {
      return FormData(
        title: twist.name,
        groups: [
          StaticFormGroup(
            items: [
              FormInfo(key: 'error', text: 'Failed to create draft twist.'),
            ],
          ),
        ],
      );
    }

    // Pre-fetch integrations and usage. Usage is sourced from the
    // SubscriptionService so the at-limit gates below re-evaluate against the
    // live plan (see _liveUsage at the tap-time buildCommands).
    final results = await Future.wait([
      TwistApi.getIntegrations(draftId),
      _freshUsage(),
      TwistInstance.get(),
    ]);
    final integrations = results[0] as TwistIntegrations;
    final usage = results[1] as UsageData;
    final twistInstances = results[2] as List<TwistInstance>;
    final teams = usage.teams;
    final availableScopes = _getAvailableScopes(twist, twistInstances, teams);

    final refreshNotifier = ValueNotifier<int>(0);

    // Track integration changes from the integrations widget
    var integrationChanges = const IntegrationChanges();

    // Build option form items
    final hasOptions =
        twist.optionsSchema != null && twist.optionsSchema!.isNotEmpty;
    final optionItems = hasOptions
        ? TwistOptionItems(options: twist.optionsSchema!)
        : null;

    // Check if twist has link permission (and is not a source)
    final hasLinkPermission =
        !twist.isSource &&
        twist.permissions != null &&
        twist.permissions!.hasPermission('plot', 'link', PermissionFlag.read);

    // Track link channel changes
    var linkChannelSelection = const LinkChannelSelection();
    final setupSourceController = FormChannelListController();
    final setupLinkController = FormChannelListController();

    // Only show a divider before the Add button when there's visible content
    // above it (team select, integrations, options, or link channels).
    // When the user has no teams and the twist has no integrations/options, the
    // form only shows the name field — a divider would look out of place.
    final hasVisibleContentAboveAddButton =
        teams.isNotEmpty ||
        integrations.providers.isNotEmpty ||
        optionItems != null ||
        hasLinkPermission;

    return FormData(
      title: 'Set up ${twist.name}',
      groups: [
        StaticFormGroup(
          items: [
            // Name field — hidden for single-instance twists
            if (twist.multipleInstances)
              FormTextInput(
                key: 'name',
                label: 'Name',
                initialValue: twist.name,
                required: true,
              ),

            // Scope select — shown only when user has teams
            if (teams.isNotEmpty)
              FormSelect<String>(
                key: 'team_id',
                label: 'Scope',
                // Prefer a team over personal so the twist counts against
                // team quota by default. User can switch in the selector.
                initialValue:
                    availableScopes.firstWhereOrNull((s) => s != 'personal') ??
                    (availableScopes.isNotEmpty
                        ? availableScopes.first
                        : 'personal'),
                items: (search) async => availableScopes,
                titleBuilder: (id) => id == 'personal'
                    ? 'Personal'
                    : teams.firstWhere((t) => t.id == id).name,
                // For single-instance twists with only one available scope,
                // show readonly so the user can see where it will be installed
                readonlyMessage:
                    !twist.multipleInstances && availableScopes.length == 1
                    ? 'Already active in all other scopes'
                    : null,
              ),
            FormChannelList(
              key: 'integrations',
              controller: setupSourceController,
              builder: (context) => SetupSourceWidget(
                twistInstanceId: draftId,
                setupMode: true,
                sourceName: twist.name,
                logoUrl: twist.logoUrl,
                logoUrlDark: twist.logoUrlDark,
                initialData: integrations,
                refreshNotifier: refreshNotifier,
                channelListController: setupSourceController,
                onChanged: (changes) {
                  integrationChanges = changes;
                },
              ),
            ),
            if (integrations.providers.isNotEmpty)
              FormButton(
                key: 'add_account',
                buildCommand: (_) => ShowAddIntegrationAccount(
                  twistInstanceId: draftId,
                  onAccountAdded: () => refreshNotifier.value++,
                ),
              ),
            if (optionItems != null) ...optionItems.items,
            if (integrations.providers.isEmpty &&
                twist.isSource &&
                optionItems != null)
              FormButton(
                key: 'connect',
                buildCommand: (values) {
                  final owner = values['team_id'] as String? ?? 'personal';
                  final live = _liveUsage(usage);
                  final premiumGate = _premiumGateCommand(
                    usage: live,
                    owner: owner,
                    isPremium: twist.premium,
                  );
                  if (premiumGate != null) return premiumGate;
                  final team = live.teams.firstWhereOrNull((t) => t.id == owner);
                  final atLimit = team != null
                      ? team.connections.isAtLimit
                      : live.personal.connections.isAtLimit;

                  if (atLimit) {
                    return _connectionAtLimitCommand();
                  }

                  return ConnectNoProviderCommand(
                    twistInstanceId: draftId,
                    optionItems: optionItems,
                    teamId: owner == 'personal' ? null : owner,
                    onConnected: (syncables) {
                      refreshNotifier.value++;
                    },
                  );
                },
              ),
            if (hasLinkPermission)
              FormChannelList(
                key: 'link_channels',
                controller: setupLinkController,
                builder: (context) => SetupLinkChannelsWidget(
                  twistInstanceId: draftId,
                  setupMode: true,
                  channelListController: setupLinkController,
                  onChanged: (selection) {
                    linkChannelSelection = selection;
                  },
                ),
              ),
            if (hasVisibleContentAboveAddButton) FormDivider(key: 'divider'),
            FormButton(
              key: 'add',
              isPrimary: true,
              buildCommand: (values) {
                final owner = values['team_id'] as String? ?? 'personal';

                // Check twist limit for non-sources
                if (!twist.isSource) {
                  final atLimit = owner == 'personal' &&
                      _liveUsage(usage).personal.twists.isAtLimit;
                  if (atLimit) {
                    return _twistAtLimitCommand();
                  }
                }

                final name = twist.multipleInstances
                    ? (values['name'] as String? ?? twist.name)
                    : twist.name;
                // Convert IntegrationChanges to SelectedChannel list
                final selectedChannels = integrationChanges.selectedChannels
                    .map((key) {
                      final parts = key.split(':');
                      return SelectedChannel(
                        provider: parts[0],
                        channelId: parts.sublist(1).join(':'),
                      );
                    })
                    .toList();
                return ActivateTwist(
                  draftId: draftId,
                  name: name,
                  config: optionItems?.values,
                  channels: selectedChannels,
                  linkChannels: hasLinkPermission
                      ? linkChannelSelection.entries
                      : null,
                  teamId: owner == 'personal' ? null : owner,
                  connectorCategory: twist.category,
                  isPremium: twist.premium,
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Activates a draft twist: flips draft=false, calls activate, enables channels.
class ActivateTwist extends Command {
  ActivateTwist({
    required this.draftId,
    required this.name,
    this.config,
    required this.channels,
    this.linkChannels,
    this.teamId,
    this.connectorCategory,
    this.isPremium,
  }) : super(
         title: 'Activate twist',
         icon: PlotIcon.twist,
         eventObject: EventObject.twist,
         eventAction: EventAction.added,
       );

  final String draftId;
  final String name;
  final Map<String, dynamic>? config;
  final List<SelectedChannel> channels;
  final List<LinkChannelEntry>? linkChannels;
  final String? teamId;

  /// Connector identity attached to the `[Action] Twist Added` event. This
  /// path (SetupTwist) has no onboarding/settings signal in scope, so it omits
  /// `context`; the AddSourceDetail path (_ActivateNoProviderSource) carries it.
  final String? connectorCategory;
  final bool? isPremium;

  @override
  Map<String, Object?> get eventProperties => {
    'connector': name,
    'connector_category': connectorCategory,
    'is_premium': isPremium,
  };

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await TwistApi.activateDraft(
        draftId: draftId,
        name: name,
        config: config,
        channels: channels.isNotEmpty
            ? channels
                  .map(
                    (s) => {'provider': s.provider, 'syncableId': s.channelId},
                  )
                  .toList()
            : null,
        teamId: teamId,
      );

      // Mark the draft as activated so cleanup doesn't delete it
      SetupTwist.clearDraft();

      // Save link channel selections if any (draftId is now the twistInstanceId)
      if (linkChannels != null && linkChannels!.isNotEmpty) {
        await TwistApi.updateLinkChannels(
          twistInstanceId: draftId,
          channels: linkChannels!.map((e) => e.toJson()).toList(),
        );
      }

      // Sync new twist to local DB
      await TwistInstance.pull();

      // A connection was added — refresh the user's connector counts on the
      // next sync.
      markUserAnalyticsProfileStale();

      // Pop all modals and reopen twist list
      if (context.mounted) {
        Modal.popAll(context);
        Future.microtask(() {
          if (context.mounted) {
            ManageTwists().run(context);
          }
        });
      }

      return const CommandDone();
    } on ApiException catch (e, t) {
      log.warning('Failed to activate twist', e, t);
      if (e.isPlanLimitExceeded) {
        return CommandMessage(
          _planLimitTwistMessage(
            isTeam: e.isTeam == true,
            isAdmin: e.isAdmin == true,
          ),
          isError: true,
        );
      }
      return CommandMessage(
        'Failed to add twist. Please try again.',
        isError: true,
      );
    } catch (e, t) {
      log.warning('Failed to activate twist', e, t);
      Tracker.captureException(e, t);
      return CommandMessage(
        'Failed to add twist. Please try again.',
        isError: true,
      );
    }
  }
}

// ============================================================================
// Connect Connector Account (streamlined auth for unconnected users)
// ============================================================================

/// Streamlined auth modal shown when a user taps a link from a source they
/// haven't connected. Shows only the twist logo/name and auth buttons.
class ConnectConnectorAccount extends ShowForm {
  ConnectConnectorAccount(TwistInstance twist)
    : super(
        title: 'Connect ${twist.name}',
        icon: PlotIcon.connection,
        constraints: const BoxConstraints(maxHeight: 200, maxWidth: 400),
        maxWidthPercentage: 0.5,
        form: (context) => _buildForm(twist),
      );

  static Future<FormData> _buildForm(TwistInstance twist) async {
    final integrations = await TwistApi.getIntegrations(twist.id.toString());

    // Individual key connector: show key entry form
    if (!integrations.shared &&
        integrations.keyOption != null &&
        integrations.providers.isEmpty) {
      return _buildKeyConnectForm(twist, integrations);
    }

    // OAuth connector: show providers the user hasn't connected to yet
    var providers = integrations.providers
        .where(
          (p) => !integrations.accounts.any((a) => a.provider == p.provider),
        )
        .toList();
    if (providers.isEmpty) {
      providers = integrations.providers;
    }
    return FormData(
      title: 'Connect ${twist.name}',
      groups: [
        StaticFormGroup(
          items: providers
              .map(
                (provider) => FormInfo(
                  key: 'auth_${provider.provider.name}',
                  divider: false,
                  builder: (formContext) => Padding(
                    padding: formContext.theme.spacing.padding.copyWith(top: 0),
                    child: AuthButton.connect(
                      provider: provider.provider,
                      scopes: provider.scopes,
                      twistInstanceId: twist.id.toString(),
                      onSuccess: () async {
                        TwistInstance.pullUpdates();
                        if (formContext.mounted) {
                          Modal.pop<CommandReturn>(
                            formContext,
                            Value(const CommandDone()),
                          );
                        }
                      },
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  /// Build a form for individual key entry (e.g. Fellow API key).
  static FormData _buildKeyConnectForm(
    TwistInstance twist,
    TwistIntegrations integrations,
  ) {
    final keyOption = integrations.keyOption!;
    final schema = integrations.optionsSchema;
    final keyDef = schema?[keyOption] as Map<String, dynamic>?;

    // Build TwistOptionItems from just the key field
    final keySchema = <String, dynamic>{
      keyOption:
          keyDef ??
          {'type': 'text', 'secure': true, 'label': 'API key', 'default': ''},
    };
    final optionItems = TwistOptionItems(options: keySchema);

    return FormData(
      title: 'Connect ${twist.name}',
      groups: [
        StaticFormGroup(
          items: [
            ...optionItems.items,
            FormButton(
              key: 'connect',
              isPrimary: true,
              skipValidation: true,
              buildCommand: (_) => ConnectNoProviderCommand(
                twistInstanceId: twist.id.toString(),
                optionItems: optionItems,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ============================================================================
// Connect No-Provider Connector
// ============================================================================

/// Connects a no-provider source by sending option values to the API.
/// If [activateAs] is provided, also activates the draft after connecting.
class ConnectNoProviderCommand extends Command {
  ConnectNoProviderCommand({
    required this.twistInstanceId,
    required this.optionItems,
    this.activateAs,
    this.onConnected,
    this.teamId,
  }) : super(
         title: 'Connect',
         icon: PlotIcon.connection,
         eventObject: EventObject.twist,
         eventAction: EventAction.updated,
       );

  final String twistInstanceId;
  final TwistOptionItems optionItems;

  /// If set, activates the draft with this name after connecting.
  final String? activateAs;

  /// Called after a successful connect (but before activation).
  final void Function(List<TwistChannel> syncables)? onConnected;

  final String? teamId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final result = await TwistApi.connectNoProvider(
        twistInstanceId: twistInstanceId,
        options: optionItems.values,
      );

      if (result.isError) {
        return CommandMessage(result.error!, isError: true);
      }

      if (result.syncables != null) {
        onConnected?.call(result.syncables!);
      }

      // Activate the draft source if requested
      if (activateAs != null) {
        await TwistApi.activateDraft(
          draftId: twistInstanceId,
          name: activateAs!,
          teamId: teamId,
        );
        AddSourceDetail.lastConnectedDraftId = twistInstanceId;
        AddSourceDetail.clearDraft();
        return const CommandDone(message: 'Connected');
      }

      // If no activation and no callback, refresh form to show channels
      if (onConnected == null) {
        AddSourceDetail._lastConnectResult = result;
        return const CommandRefresh();
      }

      return const CommandDone(message: 'Connected');
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage(e.message, isError: true);
    } catch (e, t) {
      log.warning('Failed to connect', e, t);
      Tracker.captureException(e, t);
      return const CommandMessage(
        'Failed to connect. Please try again.',
        isError: true,
      );
    }
  }
}

/// Activates a no-provider connector draft with selected channels.
class _ActivateNoProviderSource extends Command {
  _ActivateNoProviderSource({
    required this.draftId,
    required this.twistName,
    required this.getChanges,
    this.teamId,
    this.accountLabel,
    this.connectorCategory,
    this.isPremium,
    this.connectContext,
  }) : super(
         title: 'Save connection',
         icon: PlotIcon.save,
         eventObject: EventObject.twist,
         eventAction: EventAction.added,
       );

  final String draftId;
  final String twistName;
  final IntegrationChanges Function() getChanges;
  final String? teamId;

  /// Connector identity + add context, attached to the `[Action] Twist Added`
  /// event so we can answer which connector was added, whether it's premium,
  /// and whether it was added during onboarding vs. later in settings.
  final String? connectorCategory;
  final bool? isPremium;
  final String? connectContext;

  @override
  Map<String, Object?> get eventProperties => {
    'connector': twistName,
    'connector_category': connectorCategory,
    'is_premium': isPremium,
    'context': connectContext,
  };

  /// Per-connection disambiguator, applied via updateTwist after activation
  /// since activateDraft itself doesn't take a label argument.
  final String? accountLabel;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final changes = getChanges();
      final channels = changes.selectedChannels.map((key) {
        final parts = key.split(':');
        return <String, Object>{
          'provider': parts.first,
          'syncableId': parts.skip(1).join(':'),
        };
      }).toList();

      await TwistApi.activateDraft(
        draftId: draftId,
        name: twistName,
        channels: channels,
        teamId: teamId,
      );

      if (accountLabel != null) {
        try {
          await TwistApi.updateTwist(
            twistInstanceId: draftId,
            accountLabel: Value(accountLabel),
          );
        } catch (e, t) {
          log.warning('Failed to apply account label after activation', e, t);
        }
      }

      AddSourceDetail.lastConnectedDraftId = draftId;
      AddSourceDetail.lastActivatedInSetupModal = true;
      AddSourceDetail.clearDraft();

      // A connection was added — refresh connector counts on the next sync.
      markUserAnalyticsProfileStale();

      return const CommandDone();
    } on ApiException catch (e) {
      if (e.isPlanLimitExceeded) {
        return CommandMessage(
          _planLimitConnectionMessage(
            isTeam: e.isTeam == true,
            isAdmin: e.isAdmin == true,
          ),
          isError: true,
        );
      }
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage(e.message, isError: true);
    } catch (e, t) {
      log.warning('Failed to activate source', e, t);
      Tracker.captureException(e, t);
      return const CommandMessage(
        'Failed to add connection. Please try again.',
        isError: true,
      );
    }
  }
}

// ============================================================================
// Add Integration Account (sub-modal)
// ============================================================================

/// Shows branded auth buttons for available providers.
/// When a provider is authenticated, pops back and refreshes integrations.
class ShowAddIntegrationAccount extends ShowForm {
  ShowAddIntegrationAccount({
    required String twistInstanceId,
    required VoidCallback onAccountAdded,
  }) : super(
         title: 'Add account',
         icon: PlotIcon.add,
         form: (context) => _buildForm(twistInstanceId, onAccountAdded),
       );

  static Future<FormData> _buildForm(
    String twistInstanceId,
    VoidCallback onAccountAdded,
  ) async {
    final integrations = await TwistApi.getIntegrations(twistInstanceId);

    return FormData(
      title: 'Add account',
      groups: [
        StaticFormGroup(
          items: integrations.providers
              .map(
                (provider) => FormInfo(
                  key: 'auth_${provider.provider.name}',
                  divider: false,
                  builder: (formContext) => Padding(
                    padding: formContext.theme.spacing.padding.copyWith(top: 0),
                    child: AuthButton.connect(
                      provider: provider.provider,
                      scopes: provider.scopes,
                      twistInstanceId: twistInstanceId,
                      onSuccess: () async {
                        onAccountAdded();
                        if (formContext.mounted) {
                          Modal.pop<CommandReturn>(
                            formContext,
                            Value(const CommandSkipped()),
                          );
                        }
                      },
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

/// Renders a list of "what you're granting" access bullets (• + muted text).
/// Shared by the OAuth connect widget and the credential-connector form row so
/// the bullet styling stays in sync.
Widget _accessBulletList(BuildContext context, List<String> access) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final line in access)
        Padding(
          padding: EdgeInsets.only(bottom: context.theme.spacing.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '•  ',
                style: context.theme.typography.sm.copyWith(
                  color: context.theme.colors.mutedForeground,
                ),
              ),
              Expanded(
                child: Text(
                  line,
                  style: context.theme.typography.sm.copyWith(
                    color: context.theme.colors.mutedForeground,
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

/// Builds the "what you're granting" bullet list shown above credential
/// (no-provider) connect fields. Returns null when there's nothing to show.
FormItem? _accessBulletsItem(List<String>? access) {
  if (access == null || access.isEmpty) return null;
  return FormInfo(
    key: 'access',
    divider: false,
    builder: (formContext) => Padding(
      padding: EdgeInsets.only(
        left: formContext.theme.spacing.xl,
        right: formContext.theme.spacing.xl,
        bottom: formContext.theme.spacing.sm,
      ),
      child: _accessBulletList(formContext, access),
    ),
  );
}

/// Combines optional scope toggles with the auth button for a provider.
class _AuthWithScopeToggles extends StatefulWidget {
  const _AuthWithScopeToggles({
    required this.provider,
    required this.twistInstanceId,
    required this.onSuccess,
    this.initialEnabledGroups,
    this.onScopeGroupsChanged,
    this.accountHint,
    this.accountLabel,
  });

  final TwistProvider provider;
  final String twistInstanceId;
  final Future<void> Function() onSuccess;
  final Set<String>? initialEnabledGroups;
  final ValueChanged<Set<String>>? onScopeGroupsChanged;
  final String? accountHint;

  /// Human-readable account (email/name) this connection belongs to. When set,
  /// it's shown above the auth button so the user knows which account to pick —
  /// and the server rejects authenticating a different one (account-match
  /// guard in integrations.onAuth).
  final String? accountLabel;

  @override
  State<_AuthWithScopeToggles> createState() => _AuthWithScopeTogglesState();
}

class _AuthWithScopeTogglesState extends State<_AuthWithScopeToggles> {
  late final Set<String> _enabledGroups;

  @override
  void initState() {
    super.initState();
    _enabledGroups = Set.of(widget.initialEnabledGroups ?? {});
  }

  @override
  Widget build(BuildContext context) {
    final optionalScopes = widget.provider.optionalScopes;
    final access = widget.provider.access;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (access.isNotEmpty) ...[
          _accessBulletList(context, access),
          SizedBox(height: context.theme.spacing.sm),
        ],
        if (optionalScopes != null && optionalScopes.isNotEmpty) ...[
          for (final group in optionalScopes)
            Padding(
              padding: EdgeInsets.only(bottom: context.theme.spacing.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(group.label, style: context.theme.typography.md),
                        if (group.description != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              group.description!,
                              style: context.theme.typography.sm.copyWith(
                                color: context.theme.colors.mutedForeground,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // FSwitch renders large by default; the app standardises on
                  // a 32x20 FittedBox so every switch matches. See the note in
                  // lib/style/switch.dart before changing.
                  SizedBox(
                    width: 32,
                    height: 20,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: FSwitch(
                        value: _enabledGroups.contains(group.id),
                        onChange: (value) {
                          setState(() {
                            if (value) {
                              _enabledGroups.add(group.id);
                            } else {
                              _enabledGroups.remove(group.id);
                            }
                          });
                          widget.onScopeGroupsChanged?.call(_enabledGroups);
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(height: context.theme.spacing.xs),
        ],
        if (widget.accountLabel != null)
          Padding(
            padding: EdgeInsets.only(top: context.theme.spacing.md),
            child: Text(
              'Sign in as ${widget.accountLabel}',
              style: context.theme.typography.sm.copyWith(
                color: context.theme.colors.mutedForeground,
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.only(
            top: widget.accountLabel != null
                ? context.theme.spacing.xs
                : context.theme.spacing.md,
          ),
          child: AuthButton.connect(
            provider: widget.provider.provider,
            scopes: widget.provider.scopes,
            twistInstanceId: widget.twistInstanceId,
            enabledScopeGroups: _enabledGroups.isNotEmpty
                ? _enabledGroups.toList()
                : null,
            accountHint: widget.accountHint,
            onSuccess: widget.onSuccess,
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// Edit/Update/Remove commands
// ============================================================================

/// Saves source integration changes: channel toggles and account removals.
class SaveSource extends Command {
  SaveSource({
    required this.twistInstanceId,
    required this.name,
    required this.initialEnabled,
    required this.changes,
    this.optionItems,
    this.isNewlyActivated = false,
    this.teamId,
    this.accountLabel,
  }) : super(
         title: isNewlyActivated ? 'Add connection' : 'Save',
         icon: FontAwesomeIcons.check,
         eventObject: EventObject.twist,
         eventAction: EventAction.updated,
       );

  final String twistInstanceId;
  final String name;
  final Set<String> initialEnabled;
  final IntegrationChanges changes;

  /// Option items for no-provider connectors (API key, etc.).
  final TwistOptionItems? optionItems;

  /// When true, the button shows "Add connection" instead of "Save".
  final bool isNewlyActivated;

  final String? teamId;

  /// Per-connection disambiguator. Written to twist_instance.account_label
  /// and composed into the actor display name (notes/mentions).
  final String? accountLabel;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      // Newly-connected OAuth draft: the instance is still a draft, so commit
      // it by activating with exactly the chosen channels (the channels
      // validator guarantees at least one). Activation enables the channels
      // and files it under the selected team in one call; the account label is
      // applied afterwards (activateDraft takes no label). Marking it committed
      // tells EditSource.run not to delete the draft on dismissal.
      if (isNewlyActivated) {
        final channels = changes.selectedChannels.map((key) {
          final parts = key.split(':');
          return <String, Object>{
            'provider': parts.first,
            'syncableId': parts.skip(1).join(':'),
          };
        }).toList();
        await TwistApi.activateDraft(
          draftId: twistInstanceId,
          name: name,
          channels: channels,
          teamId: teamId,
        );
        if (accountLabel != null) {
          try {
            await TwistApi.updateTwist(
              twistInstanceId: twistInstanceId,
              accountLabel: Value(accountLabel),
            );
          } catch (e, t) {
            log.warning('Failed to apply account label after activation', e, t);
          }
        }
        EditSource._committed = true;
        await TwistInstance.pull();
        return CommandMessage('Connection "$name" saved');
      }

      // 0. Save updated metadata (teamId and account_label). Wrapping in
      // Value() so a null teamId is sent to the server as a clear, not
      // omitted — picking "Personal" must move the twist out of any team
      // scope, otherwise the subsequent batch enable hits the team's quota.
      await TwistApi.updateTwist(
        twistInstanceId: twistInstanceId,
        teamId: Value(teamId),
        accountLabel: Value(accountLabel),
      );

      // Update local database to immediately reflect team/label change.
      final id = Uuid.fromString(twistInstanceId);
      TwistInstanceRow? twist = TwistInstance.fromCache(id);
      twist ??= await (Store.get.select(
        TwistInstance.table,
      )..where((t) => t.id.equals(id.toBytes()))).getSingleOrNull();
      if (twist != null) {
        await Store.get
            .update(TwistInstance.table)
            .replace(
              twist.copyWith(
                teamId: Value(teamId != null ? BigInt.parse(teamId!) : null),
                accountLabel: Value(accountLabel),
              ),
            );
      }

      // 1. Save updated options if present (no-provider connectors)
      if (optionItems != null) {
        final result = await TwistApi.connectNoProvider(
          twistInstanceId: twistInstanceId,
          options: optionItems!.values,
        );
        if (result.isError) {
          return CommandMessage(result.error!, isError: true);
        }
      }

      // 1. Compute providers being removed (skip their channel changes)
      final removedProviders = changes.removedAccounts
          .map((k) => k.split(':').first)
          .toSet();

      // 2. Enable/disable channels (skip removed providers) in one batched
      // request so the server reuses a single twist wrapper and returns
      // after queuing background sync tasks, instead of paying per-channel
      // HTTP + DO spin-up + inline refresh costs. Any heavy sync the
      // connectors do (initial pulls, webhook setup) runs in background
      // tasks after this response returns.
      final toEnable = changes.selectedChannels.difference(initialEnabled);
      final toDisable = initialEnabled.difference(changes.selectedChannels);

      Map<String, String>? asEntry(String key) {
        final parts = key.split(':');
        final provider = parts[0];
        if (removedProviders.contains(provider)) return null;
        return {'provider': provider, 'syncableId': parts.sublist(1).join(':')};
      }

      final enableEntries = toEnable
          .map(asEntry)
          .whereType<Map<String, String>>()
          .toList();
      final disableEntries = toDisable
          .map(asEntry)
          .whereType<Map<String, String>>()
          .toList();

      await TwistApi.applyChannelsBatch(
        twistInstanceId: twistInstanceId,
        enable: enableEntries,
        disable: disableEntries,
      );

      // 3. Remove accounts in parallel — each call is an independent HTTP
      // request against a different provider actor, nothing to batch.
      await Future.wait(
        changes.removedAccounts.map((accountKey) {
          final parts = accountKey.split(':');
          final provider = parts[0];
          final actorId = parts.sublist(1).join(':');
          return TwistApi.removeIntegration(
            twistInstanceId: twistInstanceId,
            provider: provider,
            actorId: actorId,
          );
        }),
      );

      return CommandMessage('Connection "$name" saved');
    } on ApiException catch (e, t) {
      log.warning('Failed to save source', e, t);
      // The client's usage data can disagree with the server's view of
      // limits — pre-checks in EditSource use cached/stale usage, but the
      // server tracks live state. When we hit plan_limit_exceeded mid-save
      // (e.g. enabling a syncable trips a per-channel quota), open the
      // upgrade page directly so the user has a path forward instead of a
      // dead-end error toast.
      if (e.isPlanLimitExceeded) {
        if (context.mounted) {
          await _connectionAtLimitCommand().run(context);
        }
        return const CommandSkipped();
      }
      return CommandMessage('Failed to save connection', isError: true);
    } catch (e, t) {
      log.warning('Failed to save source', e, t);
      return CommandMessage('Failed to save connection', isError: true);
    }
  }
}

/// Saves twist name and config settings (no integrations for twists).
class SaveTwistSettings extends Command {
  SaveTwistSettings({
    required this.twistInstance,
    required this.name,
    this.config,
    this.linkChannels,
    this.teamId,
  }) : super(
         title: 'Save',
         icon: FontAwesomeIcons.check,
         eventObject: EventObject.twist,
         eventAction: EventAction.updated,
       );

  final TwistInstance twistInstance;
  final String? name;
  final Map<String, dynamic>? config;
  final List<LinkChannelEntry>? linkChannels;
  final String? teamId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      if (name == null) {
        return CommandMessage('Name is required', isError: true);
      }

      await TwistApi.updateTwist(
        twistInstanceId: twistInstance.id.toString(),
        name: name!,
        config: config,
        teamId: Value(teamId),
      );

      // Update local database to immediately reflect name and team changes.
      await Store.get
          .update(TwistInstance.table)
          .replace(
            twistInstance.copyWith(
              name: name!,
              teamId: Value(teamId != null ? BigInt.parse(teamId!) : null),
            ),
          );

      // Save link channel selections if provided
      if (linkChannels != null) {
        await TwistApi.updateLinkChannels(
          twistInstanceId: twistInstance.id.toString(),
          channels: linkChannels!.map((e) => e.toJson()).toList(),
        );
      }

      return CommandMessage('Twist "${name!}" saved');
    } catch (e, t) {
      log.warning('Failed to save twist', e, t);
      Tracker.captureException(e, t);
      return CommandMessage('Failed to save twist', isError: true);
    }
  }
}

/// Saves all edit twist changes: name, channel toggles, and account removals.
/// Used by the SetupTwist flow which still needs integration handling.
class SaveTwist extends Command {
  SaveTwist({
    required this.twistInstance,
    required this.name,
    this.config,
    required this.initialEnabled,
    required this.changes,
    this.teamId,
  }) : super(
         title: 'Save',
         icon: FontAwesomeIcons.check,
         eventObject: EventObject.twist,
         eventAction: EventAction.updated,
       );

  final TwistInstance twistInstance;
  final String? name;
  final Map<String, dynamic>? config;
  final Set<String> initialEnabled;
  final IntegrationChanges changes;
  final String? teamId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      if (name == null) {
        return CommandMessage('Name is required', isError: true);
      }

      final ptId = twistInstance.id.toString();

      // 1. Update metadata (name, config, teamId)
      await TwistApi.updateTwist(
        twistInstanceId: ptId,
        name: name!,
        config: config,
        teamId: Value(teamId),
      );

      // Update local database to immediately reflect name and team changes.
      await Store.get
          .update(TwistInstance.table)
          .replace(
            twistInstance.copyWith(
              name: name!,
              teamId: Value(teamId != null ? BigInt.parse(teamId!) : null),
            ),
          );

      // 2. Compute providers being removed (skip their channel changes)
      final removedProviders = changes.removedAccounts
          .map((k) => k.split(':').first)
          .toSet();

      // 3. Enable/disable channels (skip removed providers) via the batch
      // endpoint — one round-trip, one twist wrapper, background sync.
      final toEnable = changes.selectedChannels.difference(initialEnabled);
      final toDisable = initialEnabled.difference(changes.selectedChannels);

      Map<String, String>? asEntry(String key) {
        final parts = key.split(':');
        final provider = parts[0];
        if (removedProviders.contains(provider)) return null;
        return {'provider': provider, 'syncableId': parts.sublist(1).join(':')};
      }

      await TwistApi.applyChannelsBatch(
        twistInstanceId: ptId,
        enable: toEnable.map(asEntry).whereType<Map<String, String>>().toList(),
        disable: toDisable
            .map(asEntry)
            .whereType<Map<String, String>>()
            .toList(),
      );

      // 4. Remove accounts in parallel
      await Future.wait(
        changes.removedAccounts.map((accountKey) {
          final parts = accountKey.split(':');
          final provider = parts[0];
          final actorId = parts.sublist(1).join(':');
          return TwistApi.removeIntegration(
            twistInstanceId: ptId,
            provider: provider,
            actorId: actorId,
          );
        }),
      );

      return CommandMessage('Twist "${name!}" saved');
    } catch (e, t) {
      log.warning('Failed to save twist', e, t);
      return CommandMessage('Failed to save twist', isError: true);
    }
  }
}

class EditTwistName extends Command {
  EditTwistName(this.twistInstance, {this.name})
    : super(
        title: 'Save',
        icon: FontAwesomeIcons.check,
        eventObject: EventObject.twist,
        eventAction: EventAction.updated,
      );

  final TwistInstance twistInstance;
  final String? name;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      if (name == null) {
        return CommandMessage('Name is required', isError: true);
      }

      await TwistApi.updateTwist(
        twistInstanceId: twistInstance.id.toString(),
        name: name!,
      );

      return CommandMessage('Twist name changed to "${name!}"');
    } catch (e, t) {
      log.warning('Failed to update twist name', e, t);
      return CommandMessage('Failed to update twist name', isError: true);
    }
  }
}

class RemoveTwist extends Command {
  RemoveTwist(this.twist)
    : super(
        title: 'Remove twist',
        subtitle: 'Remove ${twist.name} from this focus',
        eventObject: EventObject.twist,
        eventAction: EventAction.archived,
        icon: FontAwesomeIcons.trash,
      );

  final TwistInstance twist;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (twist.isBuiltin) {
      return CommandMessage('The Plot twist cannot be removed', isError: true);
    }
    try {
      await TwistApi.removeTwist(twist.id.toString());

      return CommandMessage('Twist "${twist.name}" removed successfully');
    } catch (e, t) {
      log.warning('Failed to remove twist', e, t);
      return CommandMessage('Failed to remove twist', isError: true);
    }
  }
}

class PromptToArchiveTwist extends ShowForm {
  PromptToArchiveTwist(this.twist)
    : super(
        title: 'Archive',
        icon: PlotIcon.archived,
        form: (context) => _buildForm(context, twist),
      );

  final TwistInstance twist;

  static Future<FormData> _buildForm(
    BuildContext context,
    TwistInstance twist,
  ) async {
    return FormData(
      title: 'Archive twist',
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              text:
                  'Archiving this twist will remove it and archive the threads it has created.',
            ),
            FormDivider(key: 'divider'),
            FormButton(
              key: 'archive',
              isPrimary: true,
              buildCommand: (_) => ArchiveTwist(twist),
            ),
          ],
        ),
      ],
    );
  }
}

class ArchiveTwist extends Command {
  ArchiveTwist(this.twist)
    : super(
        title: 'Archive twist',
        icon: PlotIcon.archived,
        eventObject: EventObject.twist,
        eventAction: EventAction.archived,
      );

  final TwistInstance twist;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (twist.isBuiltin) {
      return CommandMessage('The Plot twist cannot be removed', isError: true);
    }
    try {
      await TwistApi.archiveAndRemoveTwist(twist.id.toString());

      // Update local database to immediately reflect the archive
      await Store.get.save(
        TwistInstance.table,
        twist.copyWith(
          archivedAt: Value(DateTime.now()),
          updatedAt: DateTime.now(),
        ),
        TwistInstancesBase(),
      );

      return CommandMessage(
        'Twist "${twist.name}" and its threads archived successfully',
      );
    } catch (e, t) {
      log.warning('Failed to archive twist', e, t);
      Tracker.captureException(e, t);
      return CommandMessage('Failed to archive twist', isError: true);
    }
  }
}

class ArchiveActivitiesCreatedByTwist extends ShowForm {
  ArchiveActivitiesCreatedByTwist(this.twist)
    : super(
        title: 'Archive threads',
        icon: PlotIcon.archived,
        form: (context) => _buildForm(context, twist),
      );

  final TwistInstance twist;

  static Future<FormData> _buildForm(
    BuildContext context,
    TwistInstance twist,
  ) async {
    // Query the count of activities created by this twist
    final count = await _getActivityCount(twist.id);

    return FormData(
      title: 'Archive threads created by twist',
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              text: count == 0
                  ? 'No threads were created by this twist.'
                  : count == 1
                  ? '1 thread was created by this twist and will be archived.'
                  : '$count threads were created by this twist and will be archived.',
            ),
            if (count > 0)
              FormButton(
                key: 'archive',
                isPrimary: true,
                buildCommand: (_) => _ArchiveActivitiesCommand(twist, count),
              ),
          ],
        ),
      ],
    );
  }

  static Future<int> _getActivityCount(Uuid twistInstanceId) async {
    try {
      final query = Store.get.select(Store.get.threads)
        ..where((a) => a.archivedAt.isNull());
      final result = await query.get();
      return result.length;
    } catch (e, t) {
      log.warning('Failed to count activities', e, t);
      return 0;
    }
  }
}

class _ArchiveActivitiesCommand extends Command {
  _ArchiveActivitiesCommand(this.twist, this.count)
    : super(
        title: 'Archive threads',
        icon: PlotIcon.archived,
        eventObject: EventObject.activity,
        eventAction: EventAction.archived,
      );

  final TwistInstance twist;
  final int count;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final now = DateTime.now();
      await (Store.get.update(Store.get.threads)
            ..where((a) => a.archivedAt.isNull()))
          .write(ThreadsCompanion(archivedAt: Value(now)));

      // Trigger sync to push archived changes to server
      Thread.push();

      return CommandMessage(
        count == 1 ? '1 thread archived' : '$count threads archived',
      );
    } catch (e, t) {
      log.warning('Failed to archive activities', e, t);
      return CommandMessage('Failed to archive threads', isError: true);
    }
  }
}

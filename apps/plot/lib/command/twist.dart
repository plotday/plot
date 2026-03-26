import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:url_launcher/url_launcher.dart';

import 'command.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/widget/auth_button.dart'
    show getAuthProviderConfig, buildAuthButtonStyle;
import 'package:plot/store/store.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/api/twist_permission.dart' show PermissionFlag;
import 'package:plot/env.dart';
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
  final String id; // priority_twist_id
  final String name;
  final String? accountName;
  final String? accountEmail;
  final String? logoUrl;
  final String? logoUrlDark;
  final AuthProvider? provider;
  final int enabledCount;

  _ActiveSource({
    required this.id,
    required this.name,
    this.accountName,
    this.accountEmail,
    this.logoUrl,
    this.logoUrlDark,
    this.provider,
    required this.enabledCount,
  });

  @override
  String get filterText => '${accountName ?? ''} $name'.trim();
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

class _LimitBanner extends _ConnectionItem {
  final String message;
  _LimitBanner(this.message);

  @override
  String get filterText => '';
}

class ManageConnections extends Command {
  ManageConnections()
    : super(
        title: 'Connections',
        description: 'Sync your accounts and data into Plot.',
        icon: PlotIcon.connection,
        eventObject: EventObject.twist,
        eventAction: EventAction.opened,
      );

  /// Cached upcoming connections data, fetched once per ManageConnections session.
  static ({List<UpcomingConnection> connections, Set<String> votedByUser})?
  _upcomingCache;

  /// Cached usage data, refreshed each fetch.
  static UsageData? _usageCache;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    _upcomingCache = null; // Reset cache for each new session
    _usageCache = null;
    try {
      // Track newly activated source so we can open EditSource after
      // SelectModal closes (avoids a flash of the list between modals).
      String? activatedSourceId;
      String? activatedSourceName;

      Future<void> Function()? refreshFn;
      await SelectModal.open<_ConnectionItem>(
        context,
        items: (search) => _fetchItems(search),
        itemBuilder: (item, isLoading) => _buildItem(item, isLoading),
        onRefreshNeeded: (refresh) => refreshFn = refresh,
        onSelect: (ctx, item, _) async {
          if (item is _LimitBanner) {
            launchUrl(Uri.parse('https://plot.day/upgrade'));
            return false;
          } else if (item is _ActiveSource) {
            await EditSource(
              priorityTwistId: item.id,
              name: item.name,
            ).run(ctx);
          } else if (item is _AvailableSource) {
            if (_usageCache != null &&
                _usageCache!.personal.connections.isAtLimit) {
              ctx.showToast(message: 'Upgrade to add more connections.');
              return false;
            }
            await AddSourceDetail(item.twist).run(ctx);
            final activatedId = AddSourceDetail.lastActivatedSourceId;
            AddSourceDetail.lastActivatedSourceId = null;
            if (activatedId != null) {
              // Close SelectModal first, then open EditSource from outer context
              activatedSourceId = activatedId;
              activatedSourceName = item.twist.name;
              return true; // Close SelectModal
            }
          } else if (item is _UpcomingConnection) {
            await _NotifyUpcomingConnection(item).run(ctx);
          }
          // Refresh items after returning from child command
          await refreshFn?.call();
          return false; // Keep SelectModal open
        },
      );

      // Open EditSource after SelectModal has closed
      if (activatedSourceId != null && context.mounted) {
        await EditSource(
          priorityTwistId: activatedSourceId!,
          name: activatedSourceName!,
          isNewlyActivated: true,
        ).run(context);
      }

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
    // Fetch sources and available twists (always refresh these).
    // Upcoming connections are cached per session to avoid slow refreshes.
    final defaultPriority = await Priority.getDefault();
    final futures = <Future<dynamic>>[
      TwistApi.getUserSources(),
      TwistApi.getAllTwists(defaultPriority),
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

    final sourcesData = results[0] as List<Map<String, dynamic>>;
    final allTwists = results[1] as List<Twist>;
    final usage = results[2] as UsageData?;
    _usageCache = usage;
    if (results.length > 3) {
      _upcomingCache =
          results[3]
              as ({
                List<UpcomingConnection> connections,
                Set<String> votedByUser,
              })?;
    }
    final upcomingResult = _upcomingCache;

    // Fetch all integrations in parallel
    final sourceIds = sourcesData.map((json) {
      final idValue = json['id'];
      return idValue is int ? idValue.toString() : idValue as String;
    }).toList();
    final integrationResults = await Future.wait(
      sourceIds.map(
        (id) => TwistApi.getIntegrations(
          id,
        ).then<TwistIntegrations?>((r) => r).catchError((_) => null),
      ),
    );

    // Build active connections
    final activeItems = <_ActiveSource>[];
    for (var i = 0; i < sourcesData.length; i++) {
      final json = sourcesData[i];
      final id = sourceIds[i];
      final integrations = integrationResults[i];

      final enabledCount = integrations != null
          ? _countEnabled(integrations.channels)
          : 0;
      final firstAccount =
          integrations != null && integrations.accounts.isNotEmpty
          ? integrations.accounts.first
          : null;

      activeItems.add(
        _ActiveSource(
          id: id,
          name: json['name'] as String,
          accountName: firstAccount?.displayName,
          accountEmail: firstAccount?.email,
          logoUrl: json['logo_url'] as String?,
          logoUrlDark: json['logo_url_dark'] as String?,
          provider: firstAccount?.provider,
          enabledCount: enabledCount,
        ),
      );
    }

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

    // Filter by search
    List<_ConnectionItem> filteredActive = activeItems;
    List<_ConnectionItem> filteredAvailable = availableItems;
    List<_ConnectionItem> filteredUpcoming = upcomingItems;
    if (search != null && search.isNotEmpty) {
      final words = search.toLowerCase().trim().split(RegExp(r'\s+'));
      bool matches(_ConnectionItem item) {
        final text = item.filterText.toLowerCase();
        return words.every(
          (w) => text.split(RegExp(r'[\s/]+')).any((fw) => fw.startsWith(w)),
        );
      }

      filteredActive = activeItems.where(matches).toList();
      filteredAvailable = availableItems.where(matches).toList();
      filteredUpcoming = upcomingItems.where(matches).toList();
    }

    // Add limit banner at top of available connections if at limit
    if (usage != null && usage.personal.connections.isAtLimit) {
      filteredAvailable = [
        _LimitBanner(
          'You\'re using ${usage.personal.connections.count} of '
          '${usage.personal.connections.limit} included connections. '
          'Upgrade for unlimited connections.',
        ),
        ...filteredAvailable,
      ];
    }

    return [
      if (filteredActive.isNotEmpty)
        SelectGroup(title: 'Active connections', items: filteredActive),
      if (filteredAvailable.isNotEmpty)
        SelectGroup(title: 'Available connections', items: filteredAvailable),
      if (filteredUpcoming.isNotEmpty)
        SelectGroup(title: 'Upcoming connections', items: filteredUpcoming),
    ];
  }

  static int _countEnabled(List<TwistChannel> channels) {
    var count = 0;
    for (final ch in channels) {
      if (ch.enabled) count++;
      count += _countEnabled(ch.children);
    }
    return count;
  }

  static Widget _buildItem(_ConnectionItem item, bool isLoading) {
    switch (item) {
      case _LimitBanner():
        return _LimitBannerRow(message: item.message);
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
    final theme = context.theme;

    // Build subtitle: account name with email if different
    String? subtitle;
    if (item.accountName != null) {
      subtitle = item.accountName!;
      if (item.accountEmail != null && item.accountEmail != item.accountName) {
        subtitle = '$subtitle · ${item.accountEmail}';
      }
    }

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
              logoUrl: item.logoUrl,
              logoUrlDark: item.logoUrlDark,
              provider: item.provider,
              size: theme.iconSizes.base,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              children: [
                Text(
                  item.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: theme.typography.md.fontSize,
                    color: theme.colors.foreground,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      subtitle,
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
          if (item.enabledCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colors.secondary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${item.enabledCount}',
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

class _LimitBannerRow extends StatelessWidget {
  const _LimitBannerRow({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(
        message,
        style: TextStyle(
          fontSize: theme.typography.sm.fontSize,
          color: theme.colors.primary,
        ),
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

/// Edit an existing source — shows integrations, channels, and management options.
class EditSource extends ShowForm {
  EditSource({
    required this.priorityTwistId,
    required this.name,
    this.isAccountBased = true,
    this.isNewlyActivated = false,
    super.subtitle,
  }) : super(
         title: name,
         icon: PlotIcon.settings,
         form: (context) => _buildForm(
           priorityTwistId,
           name,
           isAccountBased,
           isNewlyActivated,
         ),
       );

  final String priorityTwistId;
  final String name;
  final bool isAccountBased;

  /// When true, hides the Archive button (source was just set up).
  final bool isNewlyActivated;

  static Future<FormData> _buildForm(
    String priorityTwistId,
    String name,
    bool isAccountBased,
    bool isNewlyActivated,
  ) async {
    final integrations = await TwistApi.getIntegrations(priorityTwistId);
    final refreshNotifier = ValueNotifier<int>(0);
    final sourceChannelListController = FormChannelListController();

    Set<String> collectEnabled(List<TwistChannel> channels) {
      final result = <String>{};
      for (final s in channels) {
        if (s.enabled) result.add('${s.provider.name}:${s.id}');
        result.addAll(collectEnabled(s.children));
      }
      return result;
    }

    Map<String, String> collectPriorities(List<TwistChannel> channels) {
      final result = <String, String>{};
      for (final s in channels) {
        if (s.priorityId != null) {
          result['${s.provider.name}:${s.id}'] = s.priorityId!;
        }
        result.addAll(collectPriorities(s.children));
      }
      return result;
    }

    final initialEnabled = collectEnabled(integrations.channels);
    final initialPriorities = collectPriorities(integrations.channels);
    var integrationChanges = IntegrationChanges(
      selectedChannels: Set.of(initialEnabled),
      channelPriorities: Map.of(initialPriorities),
    );

    return FormData(
      title: name,
      groups: [
        StaticFormGroup(
          items: [
            FormChannelList(
              key: 'integrations',
              controller: sourceChannelListController,
              builder: (context) => SetupSourceWidget(
                priorityTwistId: priorityTwistId,
                isAccountBased: isAccountBased,
                sourceName: name,
                initialData: integrations,
                refreshNotifier: refreshNotifier,
                channelListController: sourceChannelListController,
                onChanged: (changes) {
                  integrationChanges = changes;
                },
              ),
            ),
          ],
        ),
        StaticFormGroup(
          items: [
            FormButton(
              key: 'save',
              buildCommand: (values) {
                return SaveSource(
                  priorityTwistId: priorityTwistId,
                  name: name,
                  initialEnabled: initialEnabled,
                  initialPriorities: initialPriorities,
                  changes: integrationChanges,
                );
              },
            ),
            if (!isNewlyActivated) ...[
              FormDivider(key: 'divider'),
              FormButton(
                key: 'archive',
                buildCommand: (_) => PromptToArchiveSource(
                  priorityTwistId: priorityTwistId,
                  name: name,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Archive a source with confirmation.
class PromptToArchiveSource extends ShowForm {
  PromptToArchiveSource({required this.priorityTwistId, required this.name})
    : super(
        title: 'Archive',
        icon: PlotIcon.archived,
        form: (context) => _buildForm(priorityTwistId, name),
      );

  final String priorityTwistId;
  final String name;

  static Future<FormData> _buildForm(
    String priorityTwistId,
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
              buildCommand: (_) => _ArchiveSourceCommand(priorityTwistId, name),
            ),
          ],
        ),
      ],
    );
  }
}

class _ArchiveSourceCommand extends Command {
  _ArchiveSourceCommand(this.priorityTwistId, this.name)
    : super(
        title: 'Archive connection',
        icon: PlotIcon.archived,
        eventObject: EventObject.twist,
        eventAction: EventAction.archived,
      );

  final String priorityTwistId;
  final String name;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await TwistApi.archiveAndRemoveTwist(priorityTwistId);

      // Update local database to immediately reflect the archive
      final twist = PriorityTwist.fromCache(Uuid.fromString(priorityTwistId));
      if (twist != null) {
        await Store.get.save(
          PriorityTwist.table,
          twist.copyWith(
            archivedAt: Value(DateTime.now()),
            updatedAt: DateTime.now(),
          ),
          PriorityTwistsBase(),
        );
      }

      return CommandMessage('Connection "$name" archived successfully');
    } catch (e, t) {
      log.warning('Failed to archive source', e, t);
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
        icon: PlotIcon.add,
        commandsBuilder: (context) => _getSourceCommands(),
      );

  static Future<Commands> _getSourceCommands() async {
    final defaultPriority = await Priority.getDefault();
    final allTwists = await TwistApi.getAllTwists(defaultPriority);
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

/// Shows source description and branded auth button for setup.
class AddSourceDetail extends ShowForm {
  AddSourceDetail(this.twist)
    : super(
        title: twist.name,
        subtitle: twist.description,
        icon: PlotIcon.connection,
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
      log.warning('Failed to create draft source', e, t);
      return CommandMessage(
        'Failed to set up connection. Please try again.',
        isError: true,
      );
    }

    _currentDraftId = draftId;
    lastActivatedSourceId = null;

    if (!context.mounted) return const CommandSkipped();
    final result = await super.run(context);

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

  /// Set after activation so ManageConnections can open EditSource.
  static String? lastActivatedSourceId;

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
              FormInfo(
                key: 'error',
                text: 'Failed to create draft connection.',
              ),
            ],
          ),
        ],
      );
    }

    // Pre-fetch integrations for the draft
    final integrations = await TwistApi.getIntegrations(draftId);

    return FormData(
      title: 'Set up ${twist.name}',
      groups: [
        StaticFormGroup(
          items: [
            if (twist.description != null)
              FormInfo(key: 'description', text: twist.description!),
            ...integrations.providers.map(
              (provider) => FormInfo(
                key: 'auth_${provider.provider.name}',
                divider: false,
                builder: (formContext) => Padding(
                  padding: formContext.theme.spacing.padding.copyWith(top: 0),
                  child: Padding(
                    padding: .only(top: context.theme.spacing.md),
                    child: _IntegrationAuthButton(
                      provider: provider,
                      hasExistingAccount: false,
                      priorityTwistId: draftId,
                      onSuccess: () {
                        // Activate the source (no priority needed)
                        _activateSource(formContext, draftId, twist.name);
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static Future<void> _activateSource(
    BuildContext context,
    String draftId,
    String name,
  ) async {
    try {
      await TwistApi.activateDraft(draftId: draftId, name: name);

      lastActivatedSourceId = draftId;
      clearDraft();

      if (context.mounted) {
        Modal.pop<CommandReturn>(context, Value(const CommandDone()));
      }
    } on ApiException catch (e, t) {
      log.warning('Failed to activate source', e, t);
      if (context.mounted) {
        if (e.isPlanLimitExceeded) {
          final message = e.isOrg == true
              ? (e.isAdmin == true
                    ? 'Your organization has reached its connection limit. Upgrade your plan to add more.'
                    : 'Your organization has reached its connection limit. Contact an admin to upgrade.')
              : 'You\'ve reached your connection limit. Upgrade for unlimited connections.';
          context.showToast(message: message, isError: true);
        } else {
          context.showToast(
            message: 'Failed to add connection. Please try again.',
            isError: true,
          );
        }
      }
    } catch (e, t) {
      log.warning('Failed to activate source', e, t);
      if (context.mounted) {
        context.showToast(
          message: 'Failed to add connection. Please try again.',
          isError: true,
        );
      }
    }
  }
}

// ============================================================================
// Manage Twists (non-source only)
// ============================================================================

class ManageTwists extends ShowCommands {
  ManageTwists([Priority? priority])
    : super(
        title: 'Twists',
        description: 'Add workflows and automations to your priorities.',
        icon: PlotIcon.twist,
        commandsBuilder: (context) => _getTwistCommands(priority),
      );

  /// Cached usage data for twist limit checks.
  static UsageData? _usageCache;

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
    final defaultPriority = priority ?? await Priority.getDefault();
    final results = await Future.wait([
      priority != null
          ? PriorityTwist.get(priority: priority, includeAncestors: false)
          : PriorityTwist.get(),
      TwistApi.getAllTwists(defaultPriority),
    ]);
    final priorityTwists = results[0] as List<PriorityTwist>;
    final allTwists = results[1] as List<Twist>;

    // Fetch usage to check twist limits
    UsageData? usage;
    try {
      usage = await UpgradeApi.getUsage();
    } catch (_) {}
    _usageCache = usage;

    // Filter to non-sources only
    final twistOnlyPriorityTwists = priorityTwists
        .where((pt) => !pt.isSource)
        .toList();
    final twistOnlyAvailable = allTwists.where((t) => !t.isSource).toList();

    // Fetch priorities for each twist to get their paths
    final editCommandsFutures = twistOnlyPriorityTwists.map((twist) async {
      final twistPriority = twist.priorityId != null
          ? await Priority.getOne(twist.priorityId!)
          : null;
      return EditTwist(twist, priority: twistPriority);
    });
    final editCommands = await Future.wait(editCommandsFutures);

    // Sort active twists by name, then priority path, then environment
    editCommands.sort((a, b) {
      // Primary: alphabetical by name (case-insensitive)
      final nameComparison = a.priorityTwist.name.toLowerCase().compareTo(
        b.priorityTwist.name.toLowerCase(),
      );
      if (nameComparison != 0) return nameComparison;

      // Secondary: priority path (case-insensitive)
      final aPath = a.priority?.root == true
          ? ''
          : (a.priority?.ancestorsLabel() ?? a.priority?.title ?? '');
      final bPath = b.priority?.root == true
          ? ''
          : (b.priority?.ancestorsLabel() ?? b.priority?.title ?? '');
      final pathComparison = aPath.toLowerCase().compareTo(bPath.toLowerCase());
      if (pathComparison != 0) return pathComparison;

      // Tertiary: environment (public, review, private, personal)
      return _compareEnvironment(
        a.priorityTwist.twistEnvironment,
        b.priorityTwist.twistEnvironment,
      );
    });

    final addCommands = twistOnlyAvailable
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

    // Add limit banner at top of available twists if at limit
    final List<Command> availableCommands = [
      if (usage != null && usage.personal.twists.isAtLimit)
        _UpgradeBannerCommand(
          'You\'re using ${usage.personal.twists.count} of '
          '${usage.personal.twists.limit} included '
          '${usage.personal.twists.limit == 1 ? 'twist' : 'twists'}. '
          'Upgrade for unlimited twists.',
        ),
      ...addCommands,
    ];

    return Commands(
      groups: [
        StaticCommandGroup(
          title: 'Active twists',
          commands: editCommands.toList(),
        ),
        StaticCommandGroup(
          title: 'Available twists',
          commands: availableCommands,
        ),
      ],
    );
  }
}

/// A command that displays a limit banner and opens the upgrade URL when tapped.
class _UpgradeBannerCommand extends Command {
  final String message;

  _UpgradeBannerCommand(this.message)
    : super(
        title: message,
        icon: PlotIcon.sparkles,
        eventObject: EventObject.twist,
        eventAction: EventAction.opened,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    launchUrl(Uri.parse('https://plot.day/upgrade'));
    return const CommandSkipped();
  }

  @override
  Widget? buildBody(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        message,
        style: TextStyle(
          fontSize: theme.typography.sm.fontSize,
          color: theme.colors.primary,
        ),
      ),
    );
  }
}

// ============================================================================
// Edit Twist (existing twist)
// ============================================================================

class EditTwist extends ShowForm {
  EditTwist(this.priorityTwist, {this.priority})
    : super(
        title: priorityTwist.name,
        subtitle: priority?.root == true
            ? null
            : (priority?.ancestorsLabel() ?? priority?.title),
        icon: PlotIcon.settings,
        form: (context) => _buildForm(context, priorityTwist, priority),
      );

  final PriorityTwist priorityTwist;
  final Priority? priority;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) {
    final isDark = context.colour.brightness == Brightness.dark;
    final url = isDark && priorityTwist.logoUrlDark != null
        ? priorityTwist.logoUrlDark
        : priorityTwist.logoUrl;
    if (url != null) {
      return LogoImage(url: url, size: context.theme.iconSizes.base);
    }
    return null;
  }

  static Future<FormData> _buildForm(
    BuildContext context,
    PriorityTwist priorityTwist,
    Priority? priority,
  ) async {
    try {
      // Load priority if not provided
      final loadedPriority =
          priority ??
          (priorityTwist.priorityId != null
              ? await Priority.getOne(priorityTwist.priorityId!)
              : null);

      // Fetch all twists for details (source accounts have no priority)
      if (loadedPriority == null) {
        return FormData(title: priorityTwist.name, groups: []);
      }
      final allTwists = await TwistApi.getAllTwists(loadedPriority);
      final matchingTwist = allTwists.firstWhere(
        (a) => a.id == priorityTwist.twistId.toString(),
        orElse: () => throw Exception('Twist not found'),
      );

      // Build option form items
      final hasOptions =
          matchingTwist.options != null && matchingTwist.options!.isNotEmpty;
      final optionItems = hasOptions
          ? TwistOptionItems(
              options: matchingTwist.options!,
              initialConfig: priorityTwist.config,
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

      return FormData(
        title: 'Edit ${priorityTwist.name}',
        groups: [
          StaticFormGroup(
            items: [
              FormTextInput(
                key: 'name',
                label: 'Name',
                initialValue: priorityTwist.name,
                required: true,
              ),
              if (hasLinkPermission)
                FormChannelList(
                  key: 'link_channels',
                  controller: linkChannelListController,
                  builder: (context) => SetupLinkChannelsWidget(
                    priorityTwistId: priorityTwist.id.toString(),
                    priorityId: priorityTwist.priorityId?.toString(),
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
                buildCommand: (values) {
                  final name = values['name'] as String;
                  return SaveTwistSettings(
                    priorityTwist: priorityTwist,
                    name: name,
                    config: optionItems?.values,
                    linkChannels: hasLinkPermission
                        ? linkChannelSelection.entries
                        : null,
                  );
                },
              ),
              FormDivider(key: 'divider'),
              FormButton(
                key: 'details',
                buildCommand: (_) =>
                    ShowTwistDetails(matchingTwist, priority: loadedPriority),
              ),
              FormButton(
                key: 'archive',
                buildCommand: (_) => PromptToArchiveTwist(priorityTwist),
              ),
            ],
          ),
        ],
      );
    } catch (e, t) {
      log.warning('Error loading twist details', e, t);
      // Fallback to simple form without details
      return FormData(
        title: 'Edit ${priorityTwist.name}',
        groups: [
          StaticFormGroup(
            items: [
              FormTextInput(
                key: 'name',
                label: 'Name',
                initialValue: priorityTwist.name,
                required: true,
              ),
              FormDivider(key: 'divider'),
              FormButton(
                key: 'save',
                buildCommand: (values) {
                  final name = values['name'] as String;
                  return EditTwistName(priorityTwist, name: name);
                },
              ),
              FormButton(
                key: 'archive',
                buildCommand: (_) => PromptToArchiveTwist(priorityTwist),
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
  ShowTwistDetails(this.twist, {this.priority})
    : super(
        title: 'View twist details',
        icon: PlotIcon.twist,
        form: (context) => _buildForm(twist, priority),
      );

  final Twist twist;
  final Priority? priority;

  static Future<FormData> _buildForm(Twist twist, Priority? priority) async {
    // Only fetch plan/keys info for twists that use AI
    bool? hasAiKeys;
    String? effectivePlan;
    if (twist.permissions?.forDomain('ai') != null) {
      final results = await Future.wait([
        UpgradeApi.getSubscription(),
        UpgradeApi.getAiKeys(),
      ]);
      final subscription = results[0] as SubscriptionInfo;
      final aiKeys = results[1] as List<String>;
      hasAiKeys = aiKeys.isNotEmpty;
      effectivePlan = subscription.effectivePlan;
    }

    return FormData(
      title: twist.name,
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'details',
              divider: false,
              builder: (context) => TwistDetails(
                twist: twist,
                priority: priority,
                hasAiKeys: hasAiKeys,
                effectivePlan: effectivePlan,
              ),
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
  Future<CommandReturn> run(BuildContext context) async {
    final usage = ManageTwists._usageCache;
    if (usage != null && usage.personal.twists.isAtLimit) {
      context.showToast(message: 'Upgrade to add more twists.');
      return const CommandSkipped();
    }
    return super.run(context);
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
    // Fetch subscription and AI keys in parallel
    final results = await Future.wait([
      UpgradeApi.getSubscription(),
      UpgradeApi.getAiKeys(),
    ]);
    final subscription = results[0] as SubscriptionInfo;
    final aiKeys = results[1] as List<String>;
    final hasAiKeys = aiKeys.isNotEmpty;

    // Block AI-required twists for free users without keys
    final blocked = twist.aiRequired && subscription.isFree && !hasAiKeys;

    return FormData(
      title: twist.name,
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              divider: true,
              builder: (context) => TwistDetails(
                twist: twist,
                hasAiKeys: hasAiKeys,
                effectivePlan: subscription.effectivePlan,
              ),
            ),
            if (!blocked)
              FormButton(key: 'add', buildCommand: (_) => SetupTwist(twist)),
          ],
        ),
      ],
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

  static bool _isUnderPlot(Priority priority, Priority plotPriority) {
    return priority.id == plotPriority.id ||
        plotPriority.path.isParent(priority.path);
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

    // Default to root priority ("Everything")
    final initialPriority = await Priority.getDefault();

    // Pre-fetch integrations for the draft
    final integrations = await TwistApi.getIntegrations(draftId);
    final refreshNotifier = ValueNotifier<int>(0);

    // Track integration changes from the integrations widget
    var integrationChanges = const IntegrationChanges();

    // Build option form items
    final hasOptions = twist.options != null && twist.options!.isNotEmpty;
    final optionItems = hasOptions
        ? TwistOptionItems(options: twist.options!)
        : null;

    // Check if twist has link permission (and is not a source)
    final hasLinkPermission =
        !twist.isSource &&
        twist.permissions != null &&
        twist.permissions!.hasPermission('plot', 'link', PermissionFlag.read);

    // Priority notifier for link channels to react to priority changes
    final priorityNotifier = ValueNotifier<String?>(
      initialPriority.id.toString(),
    );

    // Track link channel changes
    var linkChannelSelection = const LinkChannelSelection();
    final setupSourceController = FormChannelListController();
    final setupLinkController = FormChannelListController();

    final prioritySelect = FormSelect<Priority>(
      key: 'priority',
      label: 'Add to Priority',
      initialValue: initialPriority,
      items: (search) async {
        final priorities = await Priority.get(
          order: PriorityOrder.nested,
          search: search,
        );
        final plot = priorities.firstWhereOrNull((p) => p.key == '@plot');
        if (plot == null) return priorities;
        return priorities.where((p) => !_isUnderPlot(p, plot)).toList();
      },
      labelBuilder: (p) => PriorityLabel(priority: p),
      titleBuilder: (p) => p.ancestorsLabel() != null
          ? '${p.ancestorsLabel()}${Priority.separator}${p.title}'
          : p.title,
    );

    // Update priority notifier when selection changes
    if (hasLinkPermission) {
      prioritySelect.addListener(() {
        final selected = prioritySelect.getValue();
        if (selected != null) {
          priorityNotifier.value = selected.id.toString();
        }
      });
    }

    return FormData(
      title: 'Set up ${twist.name}',
      groups: [
        StaticFormGroup(
          items: [
            prioritySelect,
            FormTextInput(
              key: 'name',
              label: 'Name',
              initialValue: twist.name,
              required: true,
            ),
            FormChannelList(
              key: 'integrations',
              controller: setupSourceController,
              builder: (context) => SetupSourceWidget(
                priorityTwistId: draftId,
                setupMode: true,
                sourceName: twist.name,
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
                  priorityTwistId: draftId,
                  onAccountAdded: () => refreshNotifier.value++,
                ),
              ),
            if (optionItems != null) ...optionItems.items,
            if (integrations.providers.isEmpty &&
                twist.isSource &&
                optionItems != null)
              FormButton(
                key: 'connect',
                buildCommand: (_) => ConnectNoProviderCommand(
                  priorityTwistId: draftId,
                  optionItems: optionItems,
                  onConnected: (syncables) {
                    refreshNotifier.value++;
                  },
                ),
              ),
            if (hasLinkPermission)
              FormChannelList(
                key: 'link_channels',
                controller: setupLinkController,
                builder: (context) => SetupLinkChannelsWidget(
                  priorityTwistId: draftId,
                  priorityNotifier: priorityNotifier,
                  setupMode: true,
                  channelListController: setupLinkController,
                  onChanged: (selection) {
                    linkChannelSelection = selection;
                  },
                ),
              ),
          ],
        ),
        StaticFormGroup(
          items: [
            FormButton(
              key: 'add',
              buildCommand: (values) {
                final selectedPriority = values['priority'] as Priority;
                final name = values['name'] as String;
                // Update priority notifier for any last-minute change
                priorityNotifier.value = selectedPriority.id.toString();
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
                  priority: selectedPriority,
                  name: name,
                  config: optionItems?.values,
                  channels: selectedChannels,
                  linkChannels: hasLinkPermission
                      ? linkChannelSelection.entries
                      : null,
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Activates a draft twist: assigns priority, calls activate, enables channels.
class ActivateTwist extends Command {
  ActivateTwist({
    required this.draftId,
    required this.priority,
    required this.name,
    this.config,
    required this.channels,
    this.linkChannels,
  }) : super(
         title: 'Activate twist',
         icon: PlotIcon.twist,
         eventObject: EventObject.twist,
         eventAction: EventAction.added,
       );

  final String draftId;
  final Priority priority;
  final String name;
  final Map<String, dynamic>? config;
  final List<SelectedChannel> channels;
  final List<LinkChannelEntry>? linkChannels;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await TwistApi.activateDraft(
        draftId: draftId,
        priorityId: priority.id.toString(),
        name: name,
        config: config,
        channels: channels.isNotEmpty
            ? channels
                  .map(
                    (s) => {'provider': s.provider, 'syncableId': s.channelId},
                  )
                  .toList()
            : null,
      );

      // Mark the draft as activated so cleanup doesn't delete it
      SetupTwist.clearDraft();

      // Save link channel selections if any (draftId is now the priorityTwistId)
      if (linkChannels != null && linkChannels!.isNotEmpty) {
        await TwistApi.updateLinkChannels(
          priorityTwistId: draftId,
          channels: linkChannels!.map((e) => e.toJson()).toList(),
        );
      }

      // Sync new twist to local DB
      await PriorityTwist.pull();

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
          e.isOrg == true
              ? (e.isAdmin == true
                    ? 'Your organization has reached its twist limit. Upgrade your plan.'
                    : 'Your organization has reached its twist limit. Contact an admin to upgrade.')
              : 'You\'ve reached your twist limit. Upgrade for unlimited twists.',
          isError: true,
        );
      }
      return CommandMessage(
        'Failed to add twist. Please try again.',
        isError: true,
      );
    } catch (e, t) {
      log.warning('Failed to activate twist', e, t);
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
  ConnectConnectorAccount(PriorityTwist twist)
    : super(
        title: 'Connect ${twist.name}',
        icon: PlotIcon.connection,
        constraints: const BoxConstraints(maxHeight: 200, maxWidth: 400),
        maxWidthPercentage: 0.5,
        form: (context) => _buildForm(twist),
      );

  static Future<FormData> _buildForm(PriorityTwist twist) async {
    final integrations = await TwistApi.getIntegrations(twist.id.toString());
    // Show providers the user hasn't connected to yet, or all providers
    // if none are unconnected (handles backfill gap where DO storage has
    // tokens but priority_twist_connection is missing).
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
                    child: _IntegrationAuthButton(
                      provider: provider,
                      hasExistingAccount: integrations.accounts.any(
                        (a) => a.provider == provider.provider,
                      ),
                      priorityTwistId: twist.id.toString(),
                      onSuccess: () {
                        PriorityTwist.pullUpdates();
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
}

// ============================================================================
// Connect No-Provider Connector
// ============================================================================

/// Connects a no-provider source by sending option values to the API.
class ConnectNoProviderCommand extends Command {
  ConnectNoProviderCommand({
    required this.priorityTwistId,
    required this.optionItems,
    required this.onConnected,
  }) : super(
         title: 'Connect',
         icon: PlotIcon.link,
         eventObject: EventObject.twist,
         eventAction: EventAction.updated,
       );

  final String priorityTwistId;
  final TwistOptionItems optionItems;
  final void Function(List<TwistChannel> syncables) onConnected;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final result = await TwistApi.connectNoProvider(
        priorityTwistId: priorityTwistId,
        options: optionItems.values,
      );

      if (result.isError) {
        return CommandMessage(result.error!, isError: true);
      }

      if (result.syncables != null) {
        onConnected(result.syncables!);
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

// ============================================================================
// Add Integration Account (sub-modal)
// ============================================================================

/// Shows branded auth buttons for available providers.
/// When a provider is authenticated, pops back and refreshes integrations.
class ShowAddIntegrationAccount extends ShowForm {
  ShowAddIntegrationAccount({
    required String priorityTwistId,
    required VoidCallback onAccountAdded,
  }) : super(
         title: 'Add account',
         icon: PlotIcon.add,
         form: (context) => _buildForm(priorityTwistId, onAccountAdded),
       );

  static Future<FormData> _buildForm(
    String priorityTwistId,
    VoidCallback onAccountAdded,
  ) async {
    final integrations = await TwistApi.getIntegrations(priorityTwistId);

    // Check connection limits
    UsageData? usage;
    try {
      usage = await UpgradeApi.getUsage();
    } catch (_) {}

    if (usage != null && usage.personal.connections.isAtLimit) {
      return FormData(
        title: 'Add account',
        groups: [
          StaticFormGroup(
            items: [
              FormInfo(
                key: 'limit_message',
                divider: false,
                builder: (formContext) => Padding(
                  padding: formContext.theme.spacing.padding,
                  child: Text(
                    'You\'re using all ${usage!.personal.connections.limit} of your included connections. Upgrade for unlimited connections.',
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }

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
                    child: _IntegrationAuthButton(
                      provider: provider,
                      hasExistingAccount: integrations.accounts.any(
                        (a) => a.provider == provider.provider,
                      ),
                      priorityTwistId: priorityTwistId,
                      onSuccess: () {
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

class _IntegrationAuthButton extends StatefulWidget {
  const _IntegrationAuthButton({
    required this.provider,
    required this.hasExistingAccount,
    required this.priorityTwistId,
    required this.onSuccess,
  });

  final TwistProvider provider;
  final bool hasExistingAccount;
  final String priorityTwistId;
  final VoidCallback onSuccess;

  @override
  State<_IntegrationAuthButton> createState() => _IntegrationAuthButtonState();
}

class _IntegrationAuthButtonState extends State<_IntegrationAuthButton> {
  bool _isLoading = false;

  /// Whether native Google Sign-In is supported on this platform.
  bool get _useNativeGoogleSignIn =>
      !kIsWeb &&
      widget.provider.provider == AuthProvider.google &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.android);

  Future<void> _startAuth() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    final redirectUri = kIsWeb
        ? Env.webAuthCallbackUrl
        : 'plotday://auth/callback';

    String? platform;
    if (!kIsWeb) {
      if (defaultTargetPlatform == TargetPlatform.android) {
        platform = 'android';
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        platform = 'ios';
      } else {
        platform = 'desktop';
      }
    }

    try {
      // Create the server-side callback for this auth flow
      final authUrl = await TwistApi.getAuthUrl(
        priorityTwistId: widget.priorityTwistId,
        provider: widget.provider.provider.name,
        redirectUri: redirectUri,
        platform: platform,
      );

      if (_useNativeGoogleSignIn) {
        await _startNativeGoogleAuth(authUrl);
      } else {
        await _startBrowserAuth(authUrl, redirectUri);
      }

      widget.onSuccess();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        log.info('Google sign-in cancelled');
        return;
      }
      log.warning('OAuth flow failed', e);
      if (mounted) _showAuthError();
    } catch (e, t) {
      log.warning('OAuth flow failed', e, t);
      if (mounted) _showAuthError();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Use native Google Sign-In SDK on macOS/iOS/Android.
  Future<void> _startNativeGoogleAuth(TwistAuthUrl authUrl) async {
    final providerScopes = widget.provider.scopes;
    // Merge openid and email scopes so the server auth code includes an
    // id_token with email claim. Android GIS only grants explicitly requested
    // scopes; without these the token exchange returns no id_token and the
    // account shows a UUID instead of the user's email.
    final scopes = {...providerScopes, 'openid', 'email'}.toList();

    // Clear any cached sign-in so the account picker is always shown.
    await GoogleSignIn.instance.signOut();

    final GoogleSignInServerAuthorization? serverAuth;
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      // On Apple platforms, calling authorizeServer on the instance-level
      // client (null userId) triggers the combined sign-in + authorization
      // flow: one prompt with account picker + consent + server auth code.
      serverAuth = await GoogleSignIn.instance.authorizationClient
          .authorizeServer(scopes);
    } else {
      // On Android, GIS separates authentication from authorization.
      // authenticate() shows the Credential Manager account picker,
      // then authorizeServer() shows consent for the selected account.
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: scopes,
      );
      serverAuth = await account.authorizationClient.authorizeServer(scopes);
    }
    final code = serverAuth?.serverAuthCode;
    if (code == null) {
      throw Exception('No server auth code received from Google');
    }

    final callbackUri = Uri(
      path: '/auth',
      queryParameters: {
        'code': code,
        'clientId': Env.googleClientId,
        'redirectUri': Env.authServerCallbackUrl,
        'provider': 'google',
        'scopes': scopes.join(','),
        'callback': authUrl.callback,
      },
    );
    await api.post<Map<String, dynamic>>(callbackUri.toString());
  }

  /// Use FlutterWebAuth2 browser-based OAuth flow.
  Future<void> _startBrowserAuth(
    TwistAuthUrl authUrl,
    String redirectUri,
  ) async {
    final result = await FlutterWebAuth2.authenticate(
      url: authUrl.url,
      callbackUrlScheme: redirectUri.split(':').first,
    );

    final responseUri = Uri.parse(result);
    final params = responseUri.queryParameters;
    final code = params['code'];

    if (code != null) {
      final callbackUri = Uri(
        path: '/auth',
        queryParameters: {
          'code': code,
          'clientId': authUrl.clientId,
          'redirectUri': redirectUri,
          'state': authUrl.state,
        },
      );
      await api.post<Map<String, dynamic>>(callbackUri.toString());
    }
  }

  void _showAuthError() {
    final providerName =
        widget.provider.provider.name[0].toUpperCase() +
        widget.provider.provider.name.substring(1);
    context.showToast(
      message: 'Unable to connect with $providerName. Please try again.',
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = getAuthProviderConfig(widget.provider.provider);
    final label = config.buttonText;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: FButton(
        mainAxisSize: .max,
        style: buildAuthButtonStyle(context, config),
        onPress: _isLoading ? null : _startAuth,
        prefix: _isLoading
            ? Spinner(color: config.loadingColor, size: config.iconSize)
            : _buildProviderIcon(widget.provider.provider, config.iconSize),
        child: Text(
          label,
          style: context.theme.typography.md.copyWith(
            fontWeight: config.fontWeight,
            fontFamily: config.fontFamily,
            color: _isLoading ? config.disabledTextColor : config.textColor,
            height: 1,
          ),
        ),
      ),
    );
  }

  static Widget _buildProviderIcon(AuthProvider provider, double size) {
    final icon = switch (provider) {
      AuthProvider.google => 'assets/google.svg',
      AuthProvider.microsoft => 'assets/microsoft.svg',
      AuthProvider.slack => 'assets/slack.svg',
      AuthProvider.atlassian => 'assets/atlassian.svg',
      AuthProvider.linear => 'assets/linear.svg',
      AuthProvider.asana => 'assets/asana.svg',
      _ => null,
    };
    if (icon == null) return SizedBox(width: size, height: size);
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: SvgPicture.asset(icon, width: size, height: size),
      ),
    );
  }
}

// ============================================================================
// Edit/Update/Remove commands
// ============================================================================

/// Saves source integration changes: channel toggles and account removals.
class SaveSource extends Command {
  SaveSource({
    required this.priorityTwistId,
    required this.name,
    required this.initialEnabled,
    this.initialPriorities = const {},
    required this.changes,
  }) : super(
         title: 'Save',
         icon: FontAwesomeIcons.check,
         eventObject: EventObject.twist,
         eventAction: EventAction.updated,
       );

  final String priorityTwistId;
  final String name;
  final Set<String> initialEnabled;
  final Map<String, String> initialPriorities;
  final IntegrationChanges changes;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      // 1. Compute providers being removed (skip their channel changes)
      final removedProviders = changes.removedAccounts
          .map((k) => k.split(':').first)
          .toSet();

      // 2. Enable/disable channels (skip removed providers)
      final toEnable = changes.selectedChannels.difference(initialEnabled);
      final toDisable = initialEnabled.difference(changes.selectedChannels);

      for (final key in toEnable) {
        final parts = key.split(':');
        final provider = parts[0];
        if (removedProviders.contains(provider)) continue;
        final channelId = parts.sublist(1).join(':');
        await TwistApi.enableChannel(
          priorityTwistId: priorityTwistId,
          provider: provider,
          channelId: channelId,
          priorityId: changes.channelPriorities[key],
        );
      }

      for (final key in toDisable) {
        final parts = key.split(':');
        final provider = parts[0];
        if (removedProviders.contains(provider)) continue;
        final channelId = parts.sublist(1).join(':');
        await TwistApi.disableChannel(
          priorityTwistId: priorityTwistId,
          provider: provider,
          channelId: channelId,
        );
      }

      // 2b. Update priority for channels that stayed enabled but changed priority
      final stayEnabled = changes.selectedChannels.intersection(initialEnabled);
      for (final key in stayEnabled) {
        final parts = key.split(':');
        final provider = parts[0];
        if (removedProviders.contains(provider)) continue;
        final newPriority = changes.channelPriorities[key];
        final oldPriority = initialPriorities[key];
        if (newPriority != null && newPriority != oldPriority) {
          final channelId = parts.sublist(1).join(':');
          await TwistApi.setChannelPriority(
            priorityTwistId: priorityTwistId,
            provider: provider,
            channelId: channelId,
            priorityId: newPriority,
          );
        }
      }

      // 3. Remove accounts
      for (final accountKey in changes.removedAccounts) {
        final parts = accountKey.split(':');
        final provider = parts[0];
        final actorId = parts.sublist(1).join(':');
        await TwistApi.removeIntegration(
          priorityTwistId: priorityTwistId,
          provider: provider,
          actorId: actorId,
        );
      }

      return CommandMessage('Connection "$name" saved');
    } catch (e, t) {
      log.warning('Failed to save source', e, t);
      return CommandMessage('Failed to save connection', isError: true);
    }
  }
}

/// Saves twist name and config settings (no integrations for twists).
class SaveTwistSettings extends Command {
  SaveTwistSettings({
    required this.priorityTwist,
    required this.name,
    this.config,
    this.linkChannels,
  }) : super(
         title: 'Save',
         icon: FontAwesomeIcons.check,
         eventObject: EventObject.twist,
         eventAction: EventAction.updated,
       );

  final PriorityTwist priorityTwist;
  final String? name;
  final Map<String, dynamic>? config;
  final List<LinkChannelEntry>? linkChannels;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      if (name == null) {
        return CommandMessage('Name is required', isError: true);
      }

      await TwistApi.updateTwist(
        priorityTwistId: priorityTwist.id.toString(),
        name: name!,
        config: config,
      );

      // Save link channel selections if provided
      if (linkChannels != null) {
        await TwistApi.updateLinkChannels(
          priorityTwistId: priorityTwist.id.toString(),
          channels: linkChannels!.map((e) => e.toJson()).toList(),
        );
      }

      return CommandMessage('Twist "${name!}" saved');
    } catch (e, t) {
      log.warning('Failed to save twist', e, t);
      return CommandMessage('Failed to save twist', isError: true);
    }
  }
}

/// Saves all edit twist changes: name, channel toggles, and account removals.
/// Used by the SetupTwist flow which still needs integration handling.
class SaveTwist extends Command {
  SaveTwist({
    required this.priorityTwist,
    required this.name,
    this.config,
    required this.initialEnabled,
    required this.changes,
  }) : super(
         title: 'Save',
         icon: FontAwesomeIcons.check,
         eventObject: EventObject.twist,
         eventAction: EventAction.updated,
       );

  final PriorityTwist priorityTwist;
  final String? name;
  final Map<String, dynamic>? config;
  final Set<String> initialEnabled;
  final IntegrationChanges changes;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      if (name == null) {
        return CommandMessage('Name is required', isError: true);
      }

      final ptId = priorityTwist.id.toString();

      // 1. Update name and config
      await TwistApi.updateTwist(
        priorityTwistId: ptId,
        name: name!,
        config: config,
      );

      // 2. Compute providers being removed (skip their channel changes)
      final removedProviders = changes.removedAccounts
          .map((k) => k.split(':').first)
          .toSet();

      // 3. Enable/disable channels (skip removed providers)
      final toEnable = changes.selectedChannels.difference(initialEnabled);
      final toDisable = initialEnabled.difference(changes.selectedChannels);

      for (final key in toEnable) {
        final parts = key.split(':');
        final provider = parts[0];
        if (removedProviders.contains(provider)) continue;
        final channelId = parts.sublist(1).join(':');
        await TwistApi.enableChannel(
          priorityTwistId: ptId,
          provider: provider,
          channelId: channelId,
        );
      }

      for (final key in toDisable) {
        final parts = key.split(':');
        final provider = parts[0];
        if (removedProviders.contains(provider)) continue;
        final channelId = parts.sublist(1).join(':');
        await TwistApi.disableChannel(
          priorityTwistId: ptId,
          provider: provider,
          channelId: channelId,
        );
      }

      // 4. Remove accounts
      for (final accountKey in changes.removedAccounts) {
        final parts = accountKey.split(':');
        final provider = parts[0];
        final actorId = parts.sublist(1).join(':');
        await TwistApi.removeIntegration(
          priorityTwistId: ptId,
          provider: provider,
          actorId: actorId,
        );
      }

      return CommandMessage('Twist "${name!}" saved');
    } catch (e, t) {
      log.warning('Failed to save twist', e, t);
      return CommandMessage('Failed to save twist', isError: true);
    }
  }
}

class EditTwistName extends Command {
  EditTwistName(this.priorityTwist, {this.name})
    : super(
        title: 'Save',
        icon: FontAwesomeIcons.check,
        eventObject: EventObject.twist,
        eventAction: EventAction.updated,
      );

  final PriorityTwist priorityTwist;
  final String? name;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      if (name == null) {
        return CommandMessage('Name is required', isError: true);
      }

      await TwistApi.updateTwist(
        priorityTwistId: priorityTwist.id.toString(),
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
        subtitle: 'Remove ${twist.name} from this priority',
        eventObject: EventObject.twist,
        eventAction: EventAction.archived,
        icon: FontAwesomeIcons.trash,
      );

  final PriorityTwist twist;

  @override
  Future<CommandReturn> run(BuildContext context) async {
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

  final PriorityTwist twist;

  static Future<FormData> _buildForm(
    BuildContext context,
    PriorityTwist twist,
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

  final PriorityTwist twist;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await TwistApi.archiveAndRemoveTwist(twist.id.toString());

      // Update local database to immediately reflect the archive
      await Store.get.save(
        PriorityTwist.table,
        twist.copyWith(
          archivedAt: Value(DateTime.now()),
          updatedAt: DateTime.now(),
        ),
        PriorityTwistsBase(),
      );

      return CommandMessage(
        'Twist "${twist.name}" and its threads archived successfully',
      );
    } catch (e, t) {
      log.warning('Failed to archive twist', e, t);
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

  final PriorityTwist twist;

  static Future<FormData> _buildForm(
    BuildContext context,
    PriorityTwist twist,
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
                buildCommand: (_) => _ArchiveActivitiesCommand(twist, count),
              ),
          ],
        ),
      ],
    );
  }

  static Future<int> _getActivityCount(Uuid priorityTwistId) async {
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

  final PriorityTwist twist;
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

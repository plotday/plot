import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:url_launcher/url_launcher.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/command/base.dart';
import 'package:plot/env.dart';
import 'package:plot/store/store.dart' show Priority, PriorityOrder;
import 'package:plot/util/uuid.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/form_modal.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/widget/spinner.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/widget/icon.dart';
import 'logging.dart';

/// Selected channel for the setup flow.
class SelectedChannel {
  final String provider;
  final String channelId;

  const SelectedChannel({required this.provider, required this.channelId});
}

/// Tracks local integration changes (channel toggles + account removals)
/// that are deferred until Save/Add.
class IntegrationChanges {
  final Set<String> selectedChannels; // "provider:channelId" keys
  final Set<String> removedAccounts; // "provider:actorId" keys
  final Map<String, String>
  channelPriorities; // "provider:channelId" → priorityId
  final Map<String, String>
  channelCreateThreads; // "provider:channelId" → createThreads ('all'|'actionable'|'manual')

  const IntegrationChanges({
    this.selectedChannels = const {},
    this.removedAccounts = const {},
    this.channelPriorities = const {},
    this.channelCreateThreads = const {},
  });
}

/// Displays integration accounts and channel resources for a source.
/// Used in both the setup and edit twist modals.
class SetupSourceWidget extends StatefulWidget {
  const SetupSourceWidget({
    required this.priorityTwistId,
    this.setupMode = false,
    this.isAccountBased = false,
    this.sourceName,
    this.initialData,
    this.refreshNotifier,
    this.onChanged,
    this.channelListController,
    this.usage,
    super.key,
  });

  final String priorityTwistId;

  /// When true, account removal calls the API immediately (for drafts).
  /// When false (edit mode), account removal is deferred until Save.
  final bool setupMode;

  /// When true, channels require per-channel priority selection (account-based sources).
  final bool isAccountBased;

  /// Display name of the source/connector, used in channel config modal titles.
  final String? sourceName;

  /// Pre-loaded integrations data to avoid a loading spinner on open.
  final TwistIntegrations? initialData;

  /// When notified, triggers a reload of integrations data.
  final ValueNotifier<int>? refreshNotifier;

  /// Called when local integration state changes (channels or accounts).
  final ValueChanged<IntegrationChanges>? onChanged;

  /// Controller for keyboard navigation integration with FormChannelList.
  final FormChannelListController? channelListController;

  /// Usage data for checking connection limits when enabling channels.
  final UsageData? usage;

  @override
  State<SetupSourceWidget> createState() => _SetupSourceWidgetState();
}

class _SetupSourceWidgetState extends State<SetupSourceWidget> {
  TwistIntegrations? _data;
  bool _isLoading = true;
  String? _error;

  /// Locally tracked selected channel keys ("provider:channelId").
  final Set<String> _localSelectedChannels = {};

  /// Soft-removed account keys ("provider:actorId") — edit mode only.
  final Set<String> _removedAccounts = {};

  /// Tracks expanded state for nested channels in the tree view.
  final Set<String> _expandedChannels = {};

  /// Locally tracked priority assignments per channel key ("provider:channelId" → priorityId).
  final Map<String, String> _channelPriorities = {};

  /// Locally tracked createThreads per channel key ("provider:channelId" → 'all'|'actionable'|'manual').
  final Map<String, String> _channelCreateThreads = {};

  /// Cached priority names for display (priorityId → title).
  final Map<String, String> _priorityNames = {};

  /// Cached priority organizationIds for limit checks (priorityId → orgId or null).
  final Map<String, int?> _priorityOrgIds = {};

  /// Whether we've seeded _localSelectedChannels from server state (edit mode).
  bool _initializedFromServer = false;

  /// Providers currently being refreshed — keeps existing data visible.
  final Set<AuthProvider> _refreshingProviders = {};

  @override
  void initState() {
    super.initState();
    if (widget.initialData != null) {
      _data = widget.initialData;
      _isLoading = false;
      _seedLocalState(widget.initialData!);
    } else {
      _loadIntegrations();
    }
    widget.refreshNotifier?.addListener(_loadIntegrations);
  }

  @override
  void dispose() {
    widget.refreshNotifier?.removeListener(_loadIntegrations);
    super.dispose();
  }

  /// Seed local selected channels from server enabled state (edit mode only).
  void _seedLocalState(TwistIntegrations data) {
    if (!widget.setupMode && !_initializedFromServer) {
      _collectEnabledChannels(data.channels);
      _initializedFromServer = true;
      // Resolve priority names for existing channel assignments
      if (widget.isAccountBased) {
        _resolvePriorityNames();
      }
    }
  }

  /// Resolve priority names for all channel priority assignments.
  Future<void> _resolvePriorityNames() async {
    final priorityIds = _channelPriorities.values.toSet();
    for (final id in priorityIds) {
      if (_priorityNames.containsKey(id)) continue;
      try {
        final priority = await Priority.getOne(Uuid.fromString(id));
        if (mounted) {
          final ancestorTitles =
              priority.ancestors(includeSelf: true).map((a) => a.title);
          setState(() {
            _priorityNames[id] =
                ancestorTitles.join(Priority.separator);
            _priorityOrgIds[id] = priority.organizationId;
          });
        }
      } catch (_) {
        // Priority may have been deleted
      }
    }
  }

  void _collectEnabledChannels(List<TwistChannel> channels) {
    for (final channel in channels) {
      final key = '${channel.providerKey}:${channel.id}';
      if (channel.enabled) {
        _localSelectedChannels.add(key);
      }
      if (channel.priorityId != null) {
        _channelPriorities[key] = channel.priorityId!;
      }
      _channelCreateThreads[key] = channel.createThreads;
      _collectEnabledChannels(channel.children);
    }
  }

  /// Flatten all channel keys from a tree for set operations.
  Set<String> _flattenChannelKeys(List<TwistChannel> channels) {
    final keys = <String>{};
    for (final s in channels) {
      keys.add('${s.providerKey}:${s.id}');
      keys.addAll(_flattenChannelKeys(s.children));
    }
    return keys;
  }

  Future<void> _loadIntegrations() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final data = await TwistApi.getIntegrations(widget.priorityTwistId);
      if (mounted) {
        _seedLocalState(data);
        setState(() {
          _data = data;
          _isLoading = false;
        });
      }
    } catch (e, t) {
      log.warning('Failed to load integrations', e, t);
      if (mounted) {
        setState(() {
          _error = 'Failed to load integrations';
          _isLoading = false;
        });
      }
    }
  }

  /// Re-fetch the channel list from the external service for a provider,
  /// then reload integration data to pick up the updated list.
  Future<void> _refreshChannels(AuthProvider provider) async {
    setState(() => _refreshingProviders.add(provider));

    try {
      // Ask the server to re-run getChannels() on the tool
      await TwistApi.refreshChannels(
        priorityTwistId: widget.priorityTwistId,
        provider: provider.name,
      );
      if (!mounted) return;

      // Now re-fetch integration data which includes the updated channels
      final data = await TwistApi.getIntegrations(widget.priorityTwistId);
      if (!mounted) return;

      // Compute set of available channel keys from new data (including nested)
      final availableKeys = _flattenChannelKeys(data.channels);

      // Remove stale entries that no longer exist in the new data
      _localSelectedChannels.removeWhere((key) => !availableKeys.contains(key));

      setState(() {
        _data = data;
        _refreshingProviders.remove(provider);
      });
    } catch (e, t) {
      log.warning('Failed to refresh channels', e, t);
      if (mounted) {
        context.showToast(
          message: 'Failed to refresh. Please try again.',
          isError: true,
        );
        setState(() => _refreshingProviders.remove(provider));
      }
    }
  }

  /// Synchronous check if enabling [key] with [priority] would be the first
  /// channel of its type (personal or team) for this connector, and whether
  /// that type is at its connection limit.
  /// Returns an upgrade message if blocked, or null if allowed.
  String? _checkConnectionLimitSync(String key, Priority priority) {
    final usage = widget.usage;
    if (usage == null) return null;

    final isTeam = priority.organizationId != null;

    // Check if there's already another enabled channel of the same type
    for (final existingKey in _localSelectedChannels) {
      if (existingKey == key) continue;
      final existingPriorityId = _channelPriorities[existingKey];
      if (existingPriorityId == null) continue;
      // Use cached org ID if available
      if (_priorityOrgIds.containsKey(existingPriorityId)) {
        final existingIsTeam = _priorityOrgIds[existingPriorityId] != null;
        if (isTeam == existingIsTeam) return null;
      }
    }

    // This would be the first channel of this type — check limits
    if (isTeam) {
      final orgId = priority.organizationId.toString();
      final org = usage.organizations.firstWhereOrNull(
        (o) => o.id == orgId,
      );
      if (org != null && org.connections.isAtLimit) {
        return org.isAdmin
            ? '${org.name} has reached its connection limit. Upgrade to add more.'
            : '${org.name} has reached its connection limit. Contact an admin to upgrade.';
      }
    } else {
      if (usage.personal.connections.isAtLimit) {
        return 'You\'ve reached your personal connection limit. Upgrade for more.';
      }
    }

    return null;
  }

  void _handleChannelTap(TwistChannel channel) async {
    final key = '${channel.providerKey}:${channel.id}';
    final isEnabled = _localSelectedChannels.contains(key);
    final isSingleChannel = _data?.singleChannel == true;

    if (widget.isAccountBased || isSingleChannel) {
      // Resolve current priority for initial value
      final currentPriorityId = _channelPriorities[key];
      final currentCreateThreads = _channelCreateThreads[key] ?? 'all';

      Priority? currentPriority;
      if (currentPriorityId != null) {
        try {
          currentPriority = await Priority.getOne(
            Uuid.fromString(currentPriorityId),
          );
        } catch (_) {}
      }
      currentPriority ??= await Priority.getDefault();
      if (!mounted) return;

      final items = <FormItem>[
        FormSelect<Priority>(
          key: 'priority',
          label: 'Sync to',
          required: true,
          items: (search) async => Priority.excludePlot(
            await Priority.get(order: PriorityOrder.nested, search: search),
          ),
          labelBuilder: (p) => PriorityLabel(priority: p),
          titleBuilder: (p) => p.ancestorsLabel() != null
              ? '${p.ancestorsLabel()}${Priority.separator}${p.title}'
              : p.title,
          initialValue: currentPriority,
          placeholder: 'Select a priority',
        ),
        FormSelect<String>(
          key: 'createThreads',
          label: 'Create threads',
          items: (_) async => ['all', 'actionable', 'manual'],
          titleBuilder: (v) => switch (v) {
            'all' => 'For everything',
            'actionable' => 'For anything requiring action',
            'manual' => 'Add links manually',
            _ => v,
          },
          initialValue: currentCreateThreads,
          hasInitialValue: true,
        ),
        FormButton(
          key: 'save',
          buildCommand: (values) {
            final priority = values['priority'] as Priority?;
            // Check connection limit for the selected priority
            if (priority != null && !isEnabled) {
              final limitMessage = _checkConnectionLimitSync(key, priority);
              if (limitMessage != null) {
                return _UpgradeChannelCommand(limitMessage);
              }
            }
            return _CallbackCommand(
              title: 'Save',
              icon: FontAwesomeIcons.check,
              onRun: () async {
                final createThreads =
                    values['createThreads'] as String? ?? 'all';
                if (priority != null) {
                  setState(() {
                    _localSelectedChannels.add(key);
                    _channelPriorities[key] = priority.id.toString();
                    _channelCreateThreads[key] = createThreads;
                    _priorityNames[priority.id.toString()] = priority.title;
                    _priorityOrgIds[priority.id.toString()] =
                        priority.organizationId;
                  });
                  _notifyChanged();
                }
                return const CommandDone();
              },
            );
          },
        ),
      ];

      if (isEnabled) {
        items.add(FormDivider(key: 'divider'));
        items.add(
          FormButton(
            key: 'disable',
            buildCommand: (_) => _CallbackCommand(
              title: 'Disable sync',
              icon: PlotIcon.archived,
              onRun: () async {
                setState(() {
                  _localSelectedChannels.remove(key);
                  _channelPriorities.remove(key);
                  _channelCreateThreads.remove(key);
                });
                _notifyChanged();
                return const CommandDone();
              },
            ),
          ),
        );
      }

      // Build a descriptive title: "Channel from Account (Source)"
      String formTitle = channel.title;
      final data = _data;
      if (data != null) {
        final account = data.accounts
            .where((a) => a.provider == channel.provider)
            .firstOrNull;
        final parts = <String>[];
        if (account != null) parts.add(account.displayName);
        if (widget.sourceName != null) parts.add(widget.sourceName!);
        if (parts.isNotEmpty) {
          formTitle = '${channel.title} from ${parts.join(' · ')}';
        }
      }

      final formData = FormData(
        title: formTitle,
        groups: [StaticFormGroup(items: items)],
      );

      final groups = await formData.list();
      if (!mounted) return;

      await FormModal(
        formData,
        groups: groups,
        rootContext: context,
      ).run(context);
    } else {
      // Non-account-based: simple toggle
      setState(() {
        if (isEnabled) {
          _localSelectedChannels.remove(key);
          _channelPriorities.remove(key);
        } else {
          _localSelectedChannels.add(key);
        }
      });
      _notifyChanged();
    }
  }

  void _notifyChanged() {
    widget.onChanged?.call(
      IntegrationChanges(
        selectedChannels: Set.of(_localSelectedChannels),
        removedAccounts: Set.of(_removedAccounts),
        channelPriorities: Map.of(_channelPriorities),
        channelCreateThreads: Map.of(_channelCreateThreads),
      ),
    );
    // Notify form that validation state may have changed
    widget.channelListController?.notifyValidationChanged();
  }

  /// Collects toggleable channels from the tree in display order.
  List<TwistChannel> _collectToggleableChannels(
    List<TwistChannel> channels, {
    bool ancestorEnabled = false,
  }) {
    final result = <TwistChannel>[];
    for (final channel in channels) {
      final key = '${channel.providerKey}:${channel.id}';
      final isForceEnabled = ancestorEnabled;
      final isOn = _localSelectedChannels.contains(key) || isForceEnabled;
      final canToggle =
          !isForceEnabled && (widget.setupMode || channel.currentUserHasAccess);
      final isExpanded = _expandedChannels.contains(key);

      if (canToggle) {
        result.add(channel);
      }

      if (channel.hasChildren && isExpanded) {
        result.addAll(
          _collectToggleableChannels(channel.children, ancestorEnabled: isOn),
        );
      }
    }
    return result;
  }

  List<Widget> _buildChannelTree(
    List<TwistChannel> channels, {
    int depth = 0,
    bool ancestorEnabled = false,
    required List<int> focusCounter,
  }) {
    final widgets = <Widget>[];
    final controller = widget.channelListController;
    for (final channel in channels) {
      final key = '${channel.providerKey}:${channel.id}';
      final isExplicitlyEnabled = _localSelectedChannels.contains(key);
      final isForceEnabled = ancestorEnabled;
      final isOn = isExplicitlyEnabled || isForceEnabled;
      final canToggle =
          !isForceEnabled && (widget.setupMode || channel.currentUserHasAccess);
      final isExpanded = _expandedChannels.contains(key);

      // Resolve priority info for display
      final priorityId = _channelPriorities[key];
      String? priorityName;
      bool isTeamPriority = false;
      if (priorityId != null) {
        priorityName = _priorityNames[priorityId];
        isTeamPriority = _priorityOrgIds[priorityId] != null;
      }

      // Determine highlight and focus node for toggleable rows
      final int subIndex = canToggle ? focusCounter[0] : -1;
      final bool highlighted =
          controller != null &&
          canToggle &&
          controller.highlightedSubIndex == subIndex;
      final FocusNode? focusNode =
          controller != null &&
              canToggle &&
              subIndex < controller.focusNodes.length
          ? controller.focusNodes[subIndex]
          : null;

      if (canToggle) {
        focusCounter[0]++;
      }

      widgets.add(
        _ChannelRow(
          channel: channel,
          isChecked: isOn,
          canToggle: canToggle,
          onToggle: () => _handleChannelTap(channel),
          depth: depth,
          hasChildren: channel.hasChildren,
          isExpanded: isExpanded,
          onExpandToggle: channel.hasChildren
              ? () {
                  setState(() {
                    if (isExpanded) {
                      _expandedChannels.remove(key);
                    } else {
                      _expandedChannels.add(key);
                    }
                  });
                }
              : null,
          isForceEnabled: isForceEnabled,
          priorityName: widget.isAccountBased ? priorityName : null,
          isTeamPriority: widget.isAccountBased && isTeamPriority,
          highlighted: highlighted,
          focusNode: focusNode,
        ),
      );

      if (channel.hasChildren && isExpanded) {
        widgets.addAll(
          _buildChannelTree(
            channel.children,
            depth: depth + 1,
            ancestorEnabled: isOn,
            focusCounter: focusCounter,
          ),
        );
      }
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Padding(
        padding: context.theme.spacing.padding,
        child: const Center(child: Spinner()),
      );
    }

    if (_error != null) {
      return Padding(
        padding: context.theme.spacing.padding,
        child: Text(
          _error!,
          style: TextStyle(color: context.theme.colors.mutedForeground),
        ),
      );
    }

    final data = _data;
    if (data == null || data.isEmpty) {
      return const SizedBox.shrink();
    }

    // Single-channel mode: show inline config instead of channel list
    if (data.singleChannel && data.channels.length == 1) {
      return _buildSingleChannelConfig(context, data);
    }

    // Compute providers where ALL accounts are soft-removed
    final accountsByProvider = <AuthProvider, List<TwistAccount>>{};
    for (final account in data.accounts) {
      accountsByProvider.putIfAbsent(account.provider, () => []).add(account);
    }
    final fullyRemovedProviders = <AuthProvider>{};
    for (final entry in accountsByProvider.entries) {
      final allRemoved = entry.value.every(
        (a) => _removedAccounts.contains('${a.provider.name}:${a.actorId}'),
      );
      if (allRemoved) fullyRemovedProviders.add(entry.key);
    }

    // Group channels by provider
    final channelsByProvider = <AuthProvider, List<TwistChannel>>{};
    for (final channel in data.channels) {
      channelsByProvider.putIfAbsent(channel.provider, () => []).add(channel);
    }

    // Build account rows
    final accountRows = <Widget>[];
    for (final account in data.accounts) {
      final accountKey = '${account.provider.name}:${account.actorId}';
      final isRemoved = _removedAccounts.contains(accountKey);
      accountRows.add(
        _AccountRow(
          account: account,
          isRemoved: isRemoved,
          onRefresh: () => _refreshChannels(account.provider),
          isRefreshing: _refreshingProviders.contains(account.provider),
        ),
      );
    }

    // Collect toggleable channels across all visible providers for the controller
    final toggleableChannels = <TwistChannel>[];
    for (final provider in channelsByProvider.keys) {
      if (!fullyRemovedProviders.contains(provider)) {
        toggleableChannels.addAll(
          _collectToggleableChannels(channelsByProvider[provider]!),
        );
      }
    }

    // Update controller with current focusable count and activator.
    // Deferred to avoid setState() during build when count changes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.channelListController?.update(toggleableChannels.length, (
        context,
        subIndex,
      ) async {
        if (subIndex < toggleableChannels.length) {
          _handleChannelTap(toggleableChannels[subIndex]);
        }
      });
    });

    // Build channel rows for all visible providers
    final focusCounter = [0];
    final channelRows = <Widget>[];
    for (final provider in channelsByProvider.keys) {
      if (!fullyRemovedProviders.contains(provider)) {
        channelRows.addAll(
          _buildChannelTree(
            channelsByProvider[provider]!,
            focusCounter: focusCounter,
          ),
        );
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...accountRows,
        ...channelRows,
        if (channelRows.isNotEmpty || accountRows.isNotEmpty)
          SizedBox(height: context.theme.spacing.md),
      ],
    );
  }

  /// Builds inline priority + create threads config for single-channel connectors.
  Widget _buildSingleChannelConfig(
    BuildContext context,
    TwistIntegrations data,
  ) {
    final theme = context.theme;
    final channel = data.channels.first;
    final key = '${channel.providerKey}:${channel.id}';
    final isEnabled = _localSelectedChannels.contains(key);
    final priorityId = _channelPriorities[key];
    final priorityName = priorityId != null ? _priorityNames[priorityId] : null;
    final isTeamPriority =
        priorityId != null && _priorityOrgIds[priorityId] != null;
    final createThreads = _channelCreateThreads[key] ?? 'all';

    // Build account rows
    final accountRows = <Widget>[];
    for (final account in data.accounts) {
      accountRows.add(
        _AccountRow(account: account),
      );
    }

    // Notify controller: single-channel has 0 toggleable rows
    // (config is managed via the inline selectors, not channel taps)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.channelListController?.update(0, (context, subIndex) async {});
    });

    final createThreadsLabel = switch (createThreads) {
      'all' => 'For everything',
      'actionable' => 'For anything requiring action',
      'manual' => 'Add links manually',
      _ => createThreads,
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...accountRows,
        // Priority selector row
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _handleSingleChannelConfig(channel),
          child: Padding(
            padding: theme.spacing.paddingSm,
            child: Row(
              children: [
                SizedBox(width: 12.0 + theme.iconSizes.base + 12.0),
                Icon(
                  FontAwesomeIcons.folderOpen,
                  size: 14,
                  color: theme.colors.mutedForeground,
                ),
                SizedBox(width: theme.spacing.md),
                Expanded(
                  child: Text(
                    isEnabled && priorityName != null
                        ? priorityName
                        : 'Select a priority',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: theme.typography.sm.fontSize,
                      color: isEnabled && priorityName != null
                          ? theme.colors.foreground
                          : theme.colors.mutedForeground,
                    ),
                  ),
                ),
                if (isEnabled && priorityName != null)
                  Icon(
                    isTeamPriority
                        ? FontAwesomeIcons.building
                        : FontAwesomeIcons.lock,
                    size: 10,
                    color: theme.colors.mutedForeground,
                  ),
                SizedBox(width: theme.spacing.sm),
                Icon(
                  FontAwesomeIcons.chevronRight,
                  size: 10,
                  color: theme.colors.mutedForeground,
                ),
              ],
            ),
          ),
        ),
        // Create threads row
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _handleSingleChannelConfig(channel),
          child: Padding(
            padding: theme.spacing.paddingSm,
            child: Row(
              children: [
                SizedBox(width: 12.0 + theme.iconSizes.base + 12.0),
                Icon(
                  FontAwesomeIcons.listCheck,
                  size: 14,
                  color: theme.colors.mutedForeground,
                ),
                SizedBox(width: theme.spacing.md),
                Expanded(
                  child: Text(
                    createThreadsLabel,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: theme.typography.sm.fontSize,
                      color: theme.colors.mutedForeground,
                    ),
                  ),
                ),
                Icon(
                  FontAwesomeIcons.chevronRight,
                  size: 10,
                  color: theme.colors.mutedForeground,
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: theme.spacing.md),
      ],
    );
  }

  /// Opens the priority + create threads modal for a single-channel connector.
  void _handleSingleChannelConfig(TwistChannel channel) {
    // Reuse the existing account-based channel tap handler
    _handleChannelTap(channel);
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    this.isRemoved = false,
    this.onRefresh,
    this.isRefreshing = false,
  });

  final TwistAccount account;
  final bool isRemoved;
  final VoidCallback? onRefresh;
  final bool isRefreshing;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final showEmail =
        account.email != null && account.email != account.displayName;

    final iconSize = theme.iconSizes.base;

    return Opacity(
      opacity: isRemoved ? 0.4 : 1.0,
      child: Padding(
        padding: context.theme.spacing.paddingSm,
        child: Row(
          children: [
            ProviderIcon(provider: account.provider, size: iconSize),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      account.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: theme.typography.md.fontSize,
                        color: theme.colors.foreground,
                      ),
                    ),
                  ),
                  if (showEmail) ...[
                    SizedBox(width: theme.spacing.md),
                    Flexible(
                      child: Text(
                        account.email!,
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
            if (!isRemoved && onRefresh != null)
              FButton.icon(
                onPress: isRefreshing ? null : onRefresh,
                variant: FButtonVariant.ghost,
                child: isRefreshing
                    ? SizedBox(width: 14, height: 14, child: Spinner(size: 14))
                    : Icon(
                        FontAwesomeIcons.arrowsRotate,
                        size: 14,
                        color: theme.colors.mutedForeground,
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChannelRow extends StatefulWidget {
  const _ChannelRow({
    required this.channel,
    required this.isChecked,
    required this.canToggle,
    required this.onToggle,
    this.depth = 0,
    this.hasChildren = false,
    this.isExpanded = false,
    this.onExpandToggle,
    this.isForceEnabled = false,
    this.priorityName,
    this.isTeamPriority = false,
    this.highlighted = false,
    this.focusNode,
  });

  final TwistChannel channel;
  final bool isChecked;
  final bool canToggle;
  final VoidCallback onToggle;
  final int depth;
  final bool hasChildren;
  final bool isExpanded;
  final VoidCallback? onExpandToggle;
  final bool isForceEnabled;
  final String? priorityName;
  final bool isTeamPriority;
  final bool highlighted;
  final FocusNode? focusNode;

  @override
  State<_ChannelRow> createState() => _ChannelRowState();
}

class _ChannelRowState extends State<_ChannelRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final isTappable = widget.canToggle || widget.hasChildren;
    final isHighlighted = widget.highlighted || (_isHovered && isTappable);

    return Focus(
      focusNode: widget.focusNode,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.hasChildren
              ? widget.onExpandToggle
              : widget.canToggle
              ? widget.onToggle
              : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isHighlighted
                  ? theme.colors.foreground.withValues(alpha: 0.05)
                  : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: EdgeInsets.only(
                left:
                    12.0 + theme.iconSizes.base + 12.0 + (widget.depth * 24.0),
                right: theme.spacing.sm,
                top: theme.spacing.xs,
                bottom: theme.spacing.xs,
              ),
              child: Row(
                children: [
                  Padding(
                    padding: EdgeInsets.only(right: theme.spacing.sm),
                    child: SizedBox(
                      width: 10,
                      child: widget.hasChildren
                          ? Icon(
                              widget.isExpanded
                                  ? FontAwesomeIcons.chevronDown
                                  : FontAwesomeIcons.chevronRight,
                              size: 10,
                              color: theme.colors.mutedForeground,
                            )
                          : null,
                    ),
                  ),
                  Opacity(
                    opacity: widget.isForceEnabled ? 0.5 : 1.0,
                    child: IgnorePointer(
                      child: SizedBox(
                        width: 32,
                        height: 20,
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: FSwitch(
                            value: widget.isChecked,
                            onChange: (_) {},
                            enabled: widget.canToggle,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: theme.spacing.md),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            widget.channel.title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: theme.typography.sm.fontSize,
                              color: widget.canToggle
                                  ? theme.colors.foreground
                                  : theme.colors.mutedForeground,
                            ),
                          ),
                        ),
                        if (widget.priorityName != null &&
                            widget.isChecked) ...[
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: theme.spacing.sm,
                            ),
                            child: Icon(
                              FontAwesomeIcons.arrowRight,
                              size: 10,
                              color: theme.colors.mutedForeground,
                            ),
                          ),
                          Icon(
                            widget.isTeamPriority
                                ? FontAwesomeIcons.building
                                : FontAwesomeIcons.lock,
                            size: 10,
                            color: theme.colors.mutedForeground,
                          ),
                          SizedBox(width: theme.spacing.xs),
                          Flexible(
                            child: Text(
                              widget.priorityName!,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: theme.typography.sm.fontSize,
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
            ),
          ),
        ),
      ),
    );
  }
}

/// Simple command that runs a callback. Used for inline FormButton actions.
class _CallbackCommand extends Command {
  _CallbackCommand({required super.title, super.icon, required this.onRun})
    : super(eventObject: EventObject.modal, eventAction: EventAction.updated);

  final Future<CommandReturn> Function() onRun;

  @override
  Future<CommandReturn> run(BuildContext context) => onRun();
}

/// Upgrade command shown in channel config when a connection limit is reached.
class _UpgradeChannelCommand extends Command {
  _UpgradeChannelCommand(String title)
    : super(
        title: title,
        icon: PlotIcon.sparkles,
        eventObject: EventObject.modal,
        eventAction: EventAction.opened,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    launchUrl(Uri.parse('${Env.siteRoot}/upgrade'));
    return const CommandSkipped();
  }
}

class ProviderIcon extends StatelessWidget {
  final AuthProvider provider;
  final double size;

  const ProviderIcon({required this.provider, required this.size, super.key});

  @override
  Widget build(BuildContext context) {
    final icon = _getIcon();
    if (icon == null) return SizedBox(width: size, height: size);

    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: SvgPicture.asset(icon, width: size, height: size),
      ),
    );
  }

  String? _getIcon() {
    switch (provider) {
      case AuthProvider.google:
        return 'assets/google.svg';
      case AuthProvider.microsoft:
        return 'assets/microsoft.svg';
      case AuthProvider.slack:
        return 'assets/slack.svg';
      case AuthProvider.atlassian:
        return 'assets/atlassian.svg';
      case AuthProvider.linear:
        return 'assets/linear.svg';
      case AuthProvider.asana:
        return 'assets/asana.svg';
      default:
        return null;
    }
  }
}

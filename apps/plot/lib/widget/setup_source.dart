import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:plot/api/twist_api.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/channel_defaults.dart';
import 'package:plot/widget/form.dart';
import 'package:plot/widget/logo_image.dart';
import 'package:plot/widget/spinner.dart';
import 'package:plot/widget/toast.dart';
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

  const IntegrationChanges({
    this.selectedChannels = const {},
    this.removedAccounts = const {},
  });
}

/// Displays integration accounts and channel resources for a source.
/// Used in both the setup and edit twist modals.
class SetupSourceWidget extends StatefulWidget {
  const SetupSourceWidget({
    required this.twistInstanceId,
    this.setupMode = false,
    this.isAccountBased = false,
    this.sourceName,
    this.logoUrl,
    this.logoUrlDark,
    this.initialData,
    this.refreshNotifier,
    this.onChanged,
    this.channelListController,
    super.key,
  });

  final String twistInstanceId;

  /// When true, account removal calls the API immediately (for drafts).
  /// When false (edit mode), account removal is deferred until Save.
  final bool setupMode;

  /// When true, this is an account-based source (Google, Slack, etc. vs.
  /// no-provider connectors). Controls whether account rows are shown.
  final bool isAccountBased;

  /// Display name of the source/connector, used in channel config modal titles.
  final String? sourceName;

  /// Logo URL for the source, used as fallback when provider icon is unavailable.
  final String? logoUrl;

  /// Dark mode logo URL for the source.
  final String? logoUrlDark;

  /// Pre-loaded integrations data to avoid a loading spinner on open.
  final TwistIntegrations? initialData;

  /// When notified, triggers a reload of integrations data.
  final ValueNotifier<int>? refreshNotifier;

  /// Called when local integration state changes (channels or accounts).
  final ValueChanged<IntegrationChanges>? onChanged;

  /// Controller for keyboard navigation integration with FormChannelList.
  final FormChannelListController? channelListController;

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

  /// Whether we've seeded _localSelectedChannels from server state (edit mode).
  bool _initializedFromServer = false;

  /// Providers currently being refreshed — keeps existing data visible.
  final Set<AuthProvider> _refreshingProviders = {};

  /// Local state for the per-account "sync new channels" toggle. Keyed by
  /// "providerKey:actorId" — same shape as channel keys above. Seeded from
  /// the server `accounts[].autoEnableNewChannels` field.
  final Map<String, bool> _autoEnableLocalState = {};

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
  void didUpdateWidget(SetupSourceWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // After a form refresh, the parent's onChanged callback captures a new
    // variable. Re-notify so the new callback receives our current state.
    if (widget.onChanged != oldWidget.onChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _notifyChanged();
      });
    }
  }

  @override
  void dispose() {
    widget.refreshNotifier?.removeListener(_loadIntegrations);
    super.dispose();
  }

  /// Seed local selected channels from server enabled state or smart defaults.
  void _seedLocalState(TwistIntegrations data) {
    for (final account in data.accounts) {
      final key = '${account.provider.name}:${account.actorId}';
      _autoEnableLocalState.putIfAbsent(
        key,
        () => account.autoEnableNewChannels,
      );
    }

    if (_initializedFromServer) return;

    if (!widget.setupMode) {
      // Edit mode: seed from server state
      _collectEnabledChannels(data.channels);
      _initializedFromServer = true;
    } else {
      // Setup mode: compute smart defaults
      _initializedFromServer = true;
      _applySuggestedDefaults(data);
    }
  }

  Future<void> _toggleAutoEnable(TwistAccount account) async {
    final key = '${account.provider.name}:${account.actorId}';
    final current = _autoEnableLocalState[key] ?? false;
    final next = !current;

    setState(() => _autoEnableLocalState[key] = next);

    try {
      await TwistApi.setAutoEnableNewChannels(
        twistInstanceId: widget.twistInstanceId,
        provider: account.provider.name,
        actorId: account.actorId,
        enabled: next,
      );
    } catch (e, t) {
      log.warning('Failed to update sync new channels', e, t);
      if (!mounted) return;
      setState(() => _autoEnableLocalState[key] = current);
      context.showToast(
        message: 'Failed to update sync setting. Please try again.',
        isError: true,
      );
    }
  }

  /// Compute and apply smart default channel selections for setup mode.
  void _applySuggestedDefaults(TwistIntegrations data) {
    final suggestion =
        ChannelDefaultSuggester.suggest(channels: data.channels);

    setState(() {
      _localSelectedChannels.addAll(suggestion.enabledChannels);
      // The suggester can return an empty set (e.g. a connection whose only
      // channels are explicitly excluded by the connector). The form's "Add
      // connection" button is gated on at least one selected channel, so fall
      // back to the first selectable channel so setup isn't stranded on a
      // disabled button. Skip channels the connector excluded by default.
      if (_localSelectedChannels.isEmpty) {
        final firstKey = _firstSelectableChannelKey(data.channels);
        if (firstKey != null) _localSelectedChannels.add(firstKey);
      }
    });

    _notifyChanged();
  }

  static String? _firstSelectableChannelKey(List<TwistChannel> channels) {
    for (final c in channels) {
      if (c.enabledByDefault == false) continue;
      return '${c.providerKey}:${c.id}';
    }
    return null;
  }

  void _collectEnabledChannels(List<TwistChannel> channels) {
    for (final channel in channels) {
      final key = '${channel.providerKey}:${channel.id}';
      if (channel.enabled) {
        _localSelectedChannels.add(key);
      }
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
      final data = await TwistApi.getIntegrations(widget.twistInstanceId);
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
        twistInstanceId: widget.twistInstanceId,
        provider: provider.name,
      );
      if (!mounted) return;

      // Now re-fetch integration data which includes the updated channels
      final data = await TwistApi.getIntegrations(widget.twistInstanceId);
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

  void _handleChannelTap(TwistChannel channel) {
    final key = '${channel.providerKey}:${channel.id}';
    final isEnabled = _localSelectedChannels.contains(key);

    setState(() {
      if (isEnabled) {
        _localSelectedChannels.remove(key);
      } else {
        _localSelectedChannels.add(key);
      }
    });
    _notifyChanged();
  }

  /// Recursively collects all descendant channel keys from a parent channel.
  Set<String> _collectDescendantKeys(TwistChannel channel) {
    final keys = <String>{};
    for (final child in channel.children) {
      keys.add('${child.providerKey}:${child.id}');
      keys.addAll(_collectDescendantKeys(child));
    }
    return keys;
  }

  /// Disables a channel. When [cascadeIfCollapsed] is true and the channel
  /// is collapsed, also disables all descendant channels.
  void _disableChannel(TwistChannel channel, {bool cascadeIfCollapsed = false}) {
    final key = '${channel.providerKey}:${channel.id}';
    final isCollapsed = !_expandedChannels.contains(key);

    setState(() {
      _localSelectedChannels.remove(key);

      if (cascadeIfCollapsed && isCollapsed && channel.hasChildren) {
        final descendantKeys = _collectDescendantKeys(channel);
        for (final dk in descendantKeys) {
          _localSelectedChannels.remove(dk);
        }
      }
    });
    _notifyChanged();
  }

  /// Quick-toggle a channel via the switch.
  void _quickToggleChannel(TwistChannel channel) {
    final key = '${channel.providerKey}:${channel.id}';
    final isEnabled = _localSelectedChannels.contains(key);

    if (isEnabled) {
      _disableChannel(channel, cascadeIfCollapsed: true);
      return;
    }

    setState(() {
      _localSelectedChannels.add(key);
    });
    _notifyChanged();
  }

  void _notifyChanged() {
    widget.onChanged?.call(
      IntegrationChanges(
        selectedChannels: Set.of(_localSelectedChannels),
        removedAccounts: Set.of(_removedAccounts),
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
          onQuickToggle: () => _quickToggleChannel(channel),
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
          logoUrl: widget.logoUrl,
          logoUrlDark: widget.logoUrlDark,
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

    // Per-account "sync new channels" toggles, rendered at the end of the
    // channel list. Skipped for accounts whose provider is fully soft-removed.
    final autoEnableRows = <Widget>[];
    for (final account in data.accounts) {
      if (fullyRemovedProviders.contains(account.provider)) continue;
      final accountKey = '${account.provider.name}:${account.actorId}';
      if (_removedAccounts.contains(accountKey)) continue;
      autoEnableRows.add(
        _AutoEnableNewChannelsRow(
          showAccountLabel: data.accounts.length > 1,
          accountLabel: account.displayName,
          isOn: _autoEnableLocalState[accountKey] ?? false,
          onToggle: () => _toggleAutoEnable(account),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...accountRows,
        ...channelRows,
        ...autoEnableRows,
        if (channelRows.isNotEmpty ||
            accountRows.isNotEmpty ||
            autoEnableRows.isNotEmpty)
          SizedBox(height: context.theme.spacing.md),
      ],
    );
  }

  /// Builds inline display for single-channel connectors.
  ///
  /// With one implicit channel, the only meaningful action is removing the
  /// account itself — toggling the channel just disables the entire
  /// connection. Render the account row only; the single channel stays
  /// selected via `_applySuggestedDefaults` so activation/save still
  /// includes it.
  Widget _buildSingleChannelConfig(
    BuildContext context,
    TwistIntegrations data,
  ) {
    final theme = context.theme;

    final accountRows = <Widget>[];
    for (final account in data.accounts) {
      accountRows.add(
        _AccountRow(
          account: account,
          logoUrl: widget.logoUrl,
          logoUrlDark: widget.logoUrlDark,
        ),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.channelListController?.update(0, (context, subIndex) async {});
    });

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...accountRows,
        SizedBox(height: theme.spacing.md),
      ],
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    this.isRemoved = false,
    this.onRefresh,
    this.isRefreshing = false,
    this.logoUrl,
    this.logoUrlDark,
  });

  final TwistAccount account;
  final bool isRemoved;
  final VoidCallback? onRefresh;
  final bool isRefreshing;
  final String? logoUrl;
  final String? logoUrlDark;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final showEmail =
        account.email != null && account.email != account.displayName;

    final iconSize = theme.iconSizes.base;
    final manageAccessUrl = account.manageAccessUrl;
    final manageAccessLabel = _manageAccessLabel(account.provider);

    return Opacity(
      opacity: isRemoved ? 0.4 : 1.0,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.theme.spacing.xl,
          vertical: context.theme.spacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildProviderIcon(context, iconSize),
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
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: Spinner(size: 14),
                          )
                        : Icon(
                            FontAwesomeIcons.arrowsRotate,
                            size: 14,
                            color: theme.colors.mutedForeground,
                          ),
                  ),
              ],
            ),
            if (!isRemoved &&
                manageAccessUrl != null &&
                manageAccessLabel != null)
              Padding(
                padding: EdgeInsets.only(
                  left: iconSize + 12,
                  top: theme.spacing.xs,
                ),
                child: GestureDetector(
                  onTap: () => launchUrl(Uri.parse(manageAccessUrl)),
                  child: Text(
                    manageAccessLabel,
                    style: theme.typography.sm.copyWith(
                      color: theme.colors.mutedForeground,
                      decoration: TextDecoration.underline,
                      decorationColor: theme.colors.mutedForeground,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Provider-specific label for the "manage access" link. Returns null when
  /// the provider has no actionable wording (the link is hidden).
  String? _manageAccessLabel(AuthProvider provider) {
    switch (provider) {
      case AuthProvider.github:
        return 'Manage organization access on GitHub';
      default:
        return 'Manage access';
    }
  }

  Widget _buildProviderIcon(BuildContext context, double size) {
    final providerIcon = ProviderIcon(provider: account.provider, size: size);
    // If the provider has a known icon, use it
    if (providerIcon.hasIcon) return providerIcon;

    // Fall back to the source's logo URL
    final isDark = context.colour.brightness == Brightness.dark;
    final url = isDark && logoUrlDark != null ? logoUrlDark : logoUrl;
    if (url != null) {
      return LogoImage(
        url: url,
        size: size,
        fallback: providerIcon,
      );
    }
    return providerIcon;
  }
}

class _ChannelRow extends StatefulWidget {
  const _ChannelRow({
    required this.channel,
    required this.isChecked,
    required this.canToggle,
    required this.onToggle,
    this.onQuickToggle,
    this.depth = 0,
    this.hasChildren = false,
    this.isExpanded = false,
    this.onExpandToggle,
    this.isForceEnabled = false,
    this.highlighted = false,
    this.focusNode,
  });

  final TwistChannel channel;
  final bool isChecked;
  final bool canToggle;
  final VoidCallback onToggle;
  final VoidCallback? onQuickToggle;
  final int depth;
  final bool hasChildren;
  final bool isExpanded;
  final VoidCallback? onExpandToggle;
  final bool isForceEnabled;
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
          onTap: widget.canToggle ? widget.onToggle : null,
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
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.hasChildren ? widget.onExpandToggle : null,
                    child: Padding(
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
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.canToggle ? widget.onQuickToggle : null,
                    child: Opacity(
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
                  ),
                  SizedBox(width: theme.spacing.md),
                  Expanded(
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ProviderIcon extends StatelessWidget {
  final AuthProvider provider;
  final double size;

  const ProviderIcon({required this.provider, required this.size, super.key});

  bool get hasIcon => _hasIcon(provider);

  @override
  Widget build(BuildContext context) {
    final icon = _getIcon(context);
    if (icon == null) return SizedBox(width: size, height: size);

    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: SvgPicture.asset(icon, width: size, height: size),
      ),
    );
  }

  static bool _hasIcon(AuthProvider provider) {
    switch (provider) {
      case AuthProvider.google:
      case AuthProvider.microsoft:
      case AuthProvider.slack:
      case AuthProvider.atlassian:
      case AuthProvider.linear:
      case AuthProvider.asana:
      case AuthProvider.hubspot:
      case AuthProvider.airtable:
      case AuthProvider.monday:
      case AuthProvider.notion:
      case AuthProvider.discord:
      case AuthProvider.github:
        return true;
      default:
        return false;
    }
  }

  String? _getIcon(BuildContext context) {
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
      case AuthProvider.hubspot:
        return 'assets/hubspot.svg';
      case AuthProvider.airtable:
        return 'assets/airtable.svg';
      case AuthProvider.monday:
        return 'assets/monday.svg';
      case AuthProvider.notion:
        return 'assets/notion.svg';
      case AuthProvider.github:
        return context.colour.brightness == Brightness.dark
            ? 'assets/github_dark.svg'
            : 'assets/github_light.svg';
      case AuthProvider.discord:
        return 'assets/discord.svg';
      default:
        return null;
    }
  }
}

class _AutoEnableNewChannelsRow extends StatefulWidget {
  const _AutoEnableNewChannelsRow({
    required this.isOn,
    required this.onToggle,
    required this.showAccountLabel,
    required this.accountLabel,
  });

  final bool isOn;
  final VoidCallback onToggle;

  /// When the modal shows multiple accounts of the same connector, append the
  /// account label to the title so the user can tell the toggles apart.
  final bool showAccountLabel;
  final String accountLabel;

  @override
  State<_AutoEnableNewChannelsRow> createState() =>
      _AutoEnableNewChannelsRowState();
}

class _AutoEnableNewChannelsRowState extends State<_AutoEnableNewChannelsRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final title = widget.showAccountLabel
        ? 'Sync new channels · ${widget.accountLabel}'
        : 'Sync new channels';

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _isHovered
                ? theme.colors.foreground.withValues(alpha: 0.05)
                : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: EdgeInsets.only(
              left: 12.0 + theme.iconSizes.base + 12.0,
              right: theme.spacing.sm,
              top: theme.spacing.sm,
              bottom: theme.spacing.sm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Padding(
                  padding: EdgeInsets.only(right: theme.spacing.sm),
                  child: const SizedBox(width: 10),
                ),
                IgnorePointer(
                  child: SizedBox(
                    width: 32,
                    height: 20,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: FSwitch(
                        value: widget.isOn,
                        onChange: (_) {},
                      ),
                    ),
                  ),
                ),
                SizedBox(width: theme.spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: theme.typography.sm.fontSize,
                          color: theme.colors.foreground,
                        ),
                      ),
                      SizedBox(height: theme.spacing.xs),
                      Text(
                        'When a new channel is added, enable it automatically.',
                        style: TextStyle(
                          fontSize: theme.typography.xs.fontSize,
                          color: theme.colors.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

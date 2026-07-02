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
import 'package:plot/util/product_channel.dart';
import 'package:plot/widget/auth_button.dart' show AuthButton;
import 'package:plot/widget/form.dart';
import 'package:plot/widget/form_modal.dart';
import 'package:plot/widget/logo_image.dart';
import 'package:plot/widget/spinner.dart';
import 'package:plot/widget/toast.dart';
import 'logging.dart';

/// Width of the leading chevron/disclosure column in the channel tree. Reserved
/// for every row in a nesting list so labels align in one column.
const double _disclosureWidth = 16.0;

/// Left indent added per nesting level in the channel tree.
const double _channelIndent = 20.0;

/// Capitalizes the first letter (channel nouns arrive lowercase, e.g. "teams").
String _capitalize(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

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

  /// Product keys staged for re-auth (composite connections only).
  /// Task 4 reads this to drive the "Continue with Google" re-auth flow.
  final Set<String> stagedProducts;

  const IntegrationChanges({
    this.selectedChannels = const {},
    this.removedAccounts = const {},
    this.stagedProducts = const {},
  });
}

/// Displays integration accounts and channel resources for a source.
/// Used in both the setup and edit twist modals.
class SetupSourceWidget extends StatefulWidget {
  const SetupSourceWidget({
    required this.twistInstanceId,
    this.setupMode = false,
    this.isAccountBased = false,
    this.showAccounts = true,
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

  /// Whether to render the connected-account header row(s) inline above the
  /// channel list. The main setup/edit form sets this false because it renders
  /// the account at the very top of the modal (above the Label field) via
  /// [SourceAccountRow] instead.
  final bool showAccounts;

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

  /// Product keys the user has staged for re-auth (composite connections only).
  /// Populated when the user taps an off-toggle in the "Not enabled" section.
  /// Task 4 reads this via [IntegrationChanges.stagedProducts] to drive
  /// the "Continue with Google" re-auth flow.
  final Set<String> _stagedProducts = {};

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

  /// Local state for the per-account auto-threading toggle. Same key shape;
  /// seeded from the server `accounts[].autoThreadingEnabled` field.
  final Map<String, bool> _autoThreadingLocalState = {};

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
      _autoThreadingLocalState.putIfAbsent(
        key,
        () => account.autoThreadingEnabled,
      );
    }

    // M2 fix: on every reload of composite data, clear any staged product
    // keys whose status has flipped to enabled. This prevents stale staged
    // keys persisting after a successful re-auth (where the product's
    // productStatus transitions from scopeMissing → granted).
    if (data.isComposite && _stagedProducts.isNotEmpty) {
      final nowEnabled = {
        for (final s in data.productStatus ?? <ProductStatus>[])
          if (s.enabled) s.key,
      };
      _stagedProducts.removeWhere(nowEnabled.contains);
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

  Future<void> _toggleAutoThreading(TwistAccount account) async {
    final key = '${account.provider.name}:${account.actorId}';
    final current = _autoThreadingLocalState[key] ?? false;
    final next = !current;

    setState(() => _autoThreadingLocalState[key] = next);

    try {
      await TwistApi.setAutoThreadingEnabled(
        twistInstanceId: widget.twistInstanceId,
        provider: account.provider.name,
        actorId: account.actorId,
        enabled: next,
      );
    } catch (e, t) {
      log.warning('Failed to update auto-threading', e, t);
      if (!mounted) return;
      setState(() => _autoThreadingLocalState[key] = current);
      context.showToast(
        message: 'Failed to update setting. Please try again.',
        isError: true,
      );
    }
  }

  /// Compute and apply smart default channel selections for setup mode.
  void _applySuggestedDefaults(TwistIntegrations data) {
    final suggestion = ChannelDefaultSuggester.suggest(channels: data.channels);

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

    // _seedLocalState runs synchronously from initState when initialData is
    // provided, i.e. while this widget is being built as a descendant of the
    // FormModal. _notifyChanged walks up to the parent form (onChanged +
    // notifyValidationChanged → FormModalState.setState), and marking an
    // ancestor dirty during build throws. Defer to after the frame — same
    // pattern as didUpdateWidget below.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _notifyChanged();
    });
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

  /// Re-fetch channels for every visible provider (the channel-heading refresh
  /// action). Most connections have one provider; multi-account connections of
  /// the same provider collapse to a single refresh.
  Future<void> _refreshAllChannels(Iterable<AuthProvider> providers) async {
    await Future.wait(providers.toSet().map(_refreshChannels));
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
  void _disableChannel(
    TwistChannel channel, {
    bool cascadeIfCollapsed = false,
  }) {
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
        stagedProducts: Set.of(_stagedProducts),
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
    required bool reserveDisclosure,
    FormChannelListController? controller,
    void Function()? onAfterTap,
  }) {
    final widgets = <Widget>[];
    // Drill-down modals pass their OWN controller so the channel rows read that
    // modal's keyboard focus state (highlight + focus nodes), not the parent's.
    final ctrl = controller ?? widget.channelListController;
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
          ctrl != null &&
          canToggle &&
          ctrl.highlightedSubIndex == subIndex;
      final FocusNode? focusNode =
          ctrl != null &&
              canToggle &&
              subIndex < ctrl.focusNodes.length
          ? ctrl.focusNodes[subIndex]
          : null;

      if (canToggle) {
        focusCounter[0]++;
      }

      widgets.add(
        _ChannelRow(
          channel: channel,
          isChecked: isOn,
          canToggle: canToggle,
          // _handleChannelTap setStates the parent; in a drill-down modal that
          // doesn't rebuild this subtree, so onAfterTap fires the modal's local
          // rebuild (mirrors the keyboard activator). Null on the main form.
          onToggle: () {
            _handleChannelTap(channel);
            onAfterTap?.call();
          },
          onQuickToggle: () {
            _quickToggleChannel(channel);
            onAfterTap?.call();
          },
          depth: depth,
          reserveDisclosure: reserveDisclosure,
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
                  onAfterTap?.call();
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
            reserveDisclosure: reserveDisclosure,
            controller: controller,
            onAfterTap: onAfterTap,
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

    // Composite mode: render ENABLED / NOT-ENABLED product sections.
    // GATED: only when products list is non-empty. The non-composite path
    // below is byte-unchanged — this guard is a clean early return.
    if (data.isComposite) {
      return _buildCompositeView(context, data);
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

    // Build account rows. Suppressed when the host form renders the account
    // header itself (above the Label field) — see [showAccounts].
    final accountRows = <Widget>[];
    if (widget.showAccounts) {
      for (final account in data.accounts) {
        final accountKey = '${account.provider.name}:${account.actorId}';
        final isRemoved = _removedAccounts.contains(accountKey);
        accountRows.add(
          SourceAccountRow(
            account: account,
            isRemoved: isRemoved,
            logoUrl: widget.logoUrl,
            logoUrlDark: widget.logoUrlDark,
          ),
        );
      }
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

    // Reserve a leading chevron gutter only when the list actually nests, so
    // flat channel lists sit flush-left with the other form fields while
    // nested lists keep every label aligned in one column.
    final reserveDisclosure = data.channels.any((c) => c.hasChildren);

    // Build channel rows for all visible providers
    final focusCounter = [0];
    final channelRows = <Widget>[];
    for (final provider in channelsByProvider.keys) {
      if (!fullyRemovedProviders.contains(provider)) {
        channelRows.addAll(
          _buildChannelTree(
            channelsByProvider[provider]!,
            focusCounter: focusCounter,
            reserveDisclosure: reserveDisclosure,
          ),
        );
      }
    }

    // Per-account "sync new channels" toggles, rendered at the end of the
    // channel list. Skipped for accounts whose provider is fully soft-removed,
    // and entirely suppressed for connectors with a fixed channel set
    // (fixedChannels) — there are no new channels to auto-enable, so the toggle
    // would be meaningless (e.g. LinkedIn: Messages + Public Post).
    final autoEnableRows = <Widget>[];
    for (final account
        in data.fixedChannels ? const <TwistAccount>[] : data.accounts) {
      if (fullyRemovedProviders.contains(account.provider)) continue;
      final accountKey = '${account.provider.name}:${account.actorId}';
      if (_removedAccounts.contains(accountKey)) continue;
      autoEnableRows.add(
        _AutoEnableNewChannelsRow(
          noun: data.channelNoun,
          showAccountLabel: data.accounts.length > 1,
          accountLabel: account.displayName,
          isOn: _autoEnableLocalState[accountKey] ?? false,
          onToggle: () => _toggleAutoEnable(account),
          reserveDisclosure: reserveDisclosure,
        ),
      );
      // Auto-threading toggle, only for connectors that support it.
      if (data.autoThreading) {
        autoEnableRows.add(
          _AutoThreadingRow(
            showAccountLabel: data.accounts.length > 1,
            accountLabel: account.displayName,
            isOn: _autoThreadingLocalState[accountKey] ?? false,
            onToggle: () => _toggleAutoThreading(account),
            reserveDisclosure: reserveDisclosure,
          ),
        );
      }
    }

    // Providers whose channel list the refresh button re-fetches.
    final refreshableProviders = channelsByProvider.keys
        .where((p) => !fullyRemovedProviders.contains(p))
        .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...accountRows,
        // Heading above the channel toggles, e.g. "Teams to sync". Uses the
        // connector's own word for its channels and carries the refresh action.
        if (channelRows.isNotEmpty)
          _ChannelSectionHeader(
            title: '${_capitalize(data.channelNoun.plural)} to sync',
            isRefreshing: _refreshingProviders.isNotEmpty,
            onRefresh: refreshableProviders.isEmpty
                ? null
                : () => _refreshAllChannels(refreshableProviders),
          ),
        ...channelRows,
        ...autoEnableRows,
        if (channelRows.isNotEmpty ||
            accountRows.isNotEmpty ||
            autoEnableRows.isNotEmpty)
          SizedBox(height: context.theme.spacing.md),
      ],
    );
  }

  /// Builds the composite product-status view.
  ///
  /// Renders a **single flat product list** — no "Enabled"/"Not enabled"
  /// section headers. Each product occupies one focusable row: icon + label +
  /// short summary + optional `›` drill-in chevron + trailing toggle.
  ///
  /// - For products **with channels** (`channelsByProduct[key]` non-empty or
  ///   the product is enabled), tapping the row or pressing Enter opens a
  ///   channel drill-down modal ([_openProductChannels]).
  /// - For **channelless** products (Contacts — no channels after grouping),
  ///   tapping the row / Enter **toggles** the product status instead.
  /// - The **trailing toggle** is always directly tappable (quick enable/
  ///   disable), decoupled from the row tap via a separate GestureDetector.
  ///
  /// Toggling a not-yet-granted product ON stages it in [_stagedProducts];
  /// toggling an enabled product OFF turns all its channels off locally.
  ///
  /// Every product row is registered as a focusable sub-item of the
  /// [FormChannelListController] so it integrates with the form's Tab / ↑↓
  /// keyboard navigation and Enter activation.
  ///
  /// Channels whose product key is not in [TwistIntegrations.products] fall
  /// through to a defensive flat-rendered group after the product list.
  ///
  /// The existing [_localSelectedChannels] key format is preserved unchanged.
  Widget _buildCompositeView(BuildContext context, TwistIntegrations data) {
    final theme = context.theme;
    final products = data.products!;
    final statusByKey = {
      for (final s in data.productStatus ?? <ProductStatus>[]) s.key: s,
    };

    // Group channels by product key (first colon segment of channel.id).
    final channelsByProduct = <String, List<TwistChannel>>{};
    final orphanChannels = <TwistChannel>[];
    for (final channel in data.channels) {
      final pk = productKeyOf(channel.id);
      if (pk != null && products.any((p) => p.key == pk)) {
        channelsByProduct.putIfAbsent(pk, () => []).add(channel);
      } else {
        orphanChannels.add(channel);
      }
    }

    // Build account rows (same as flat path).
    final accountRows = <Widget>[];
    if (widget.showAccounts) {
      for (final account in data.accounts) {
        final accountKey = '${account.provider.name}:${account.actorId}';
        final isRemoved = _removedAccounts.contains(accountKey);
        accountRows.add(
          SourceAccountRow(
            account: account,
            isRemoved: isRemoved,
            logoUrl: widget.logoUrl,
            logoUrlDark: widget.logoUrlDark,
          ),
        );
      }
    }

    // Register every product row as a focusable sub-item (one per product).
    // The activator opens the drill-down for products with channels, or
    // toggles the product for channelless ones.
    final focusCounter = [0];
    final controller = widget.channelListController;

    // Build product rows — flat, in products order.
    final rows = <Widget>[];

    for (final product in products) {
      final status = statusByKey[product.key];
      final isEnabled = status?.enabled == true;
      // Scope is granted unless the server explicitly reports it missing. This
      // is the pivot for the whole row: a scope-granted product (whether
      // `granted`, `no-channels`, or `locally-off`) is toggled/refined LOCALLY
      // and saved — never re-authed. Only `scope-missing` stages a re-auth
      // (§1.4). On a fresh connect every owned product is `no-channels`
      // server-side (nothing saved yet) but scope IS granted, so it must read
      // ON from the locally-seeded enabledByDefault channels (§1.2/§1.3) — the
      // bug was keying the toggle off the server `enabled` flag instead.
      final scopeGranted =
          status?.reason != ProductStatusReason.scopeMissing;
      final productChannels = channelsByProduct[product.key] ?? [];
      // Drill only when there's an actual choice of channels (>1). Single- or
      // zero-channel products (e.g. Contacts) are a plain toggle — no drill.
      final canDrill = scopeGranted && productChannels.length > 1;
      final anyChannelOn = productChannels.any(
        (c) => _localSelectedChannels.contains('${c.providerKey}:${c.id}'),
      );
      final isStaged = _stagedProducts.contains(product.key);

      // The trailing toggle IS the status: scope granted AND (no channels, or a
      // channel selected locally); a scope-missing product reflects whether
      // it's staged for re-auth.
      final bool toggleOn = scopeGranted
          ? (productChannels.isEmpty ? true : anyChannelOn)
          : isStaged;

      // "Not synced" reflects whether the product will sync: it's syncing on the
      // server now (`isEnabled`), OR scope is granted and at least one channel
      // is selected locally (a fresh-connect seed or a pending enable). A
      // server-synced product the user toggles off keeps its synced summary
      // until saved (still `isEnabled`), so toggling never spuriously flips the
      // label to "Not synced". When synced: multi-channel shows the selected
      // count; single/channelless shows nothing (the on-toggle conveys it).
      final bool isSynced = isEnabled || (scopeGranted && anyChannelOn);
      String summary;
      if (!isSynced) {
        summary = 'Not synced';
      } else if (productChannels.length > 1) {
        final n = productChannels
            .where(
              (c) => _localSelectedChannels.contains('${c.providerKey}:${c.id}'),
            )
            .length;
        summary = n == 0
            ? ''
            : n == 1
                ? '1 ${data.channelNoun.singular}'
                : '$n ${data.channelNoun.plural}';
      } else {
        summary = '';
      }

      // Toggle = status. Scope granted → enabling/disabling is LOCAL: off→on
      // selects the product's channel(s), on→off clears them (saved via
      // activateDraft / the batch endpoint). Only a scope-MISSING product
      // stages a re-auth (the "Continue with Google" CTA, §1.4).
      void toggleProduct() {
        setState(() {
          if (scopeGranted) {
            for (final ch in productChannels) {
              final key = '${ch.providerKey}:${ch.id}';
              if (anyChannelOn) {
                _localSelectedChannels.remove(key);
              } else {
                _localSelectedChannels.add(key);
              }
            }
          } else if (isStaged) {
            _stagedProducts.remove(product.key);
          } else {
            _stagedProducts.add(product.key);
          }
        });
        _notifyChanged();
      }

      // Row / Enter activation: drill into channels when there's a choice,
      // otherwise toggle status.
      final void Function() onRowTap = canDrill
          ? () => _openProductChannels(context, product, productChannels, data)
          : toggleProduct;

      final int subIndex = focusCounter[0];
      focusCounter[0]++;

      final bool highlighted =
          controller != null && controller.highlightedSubIndex == subIndex;
      final FocusNode? focusNode =
          controller != null && subIndex < controller.focusNodes.length
              ? controller.focusNodes[subIndex]
              : null;

      rows.add(
        _CompositeProductRow(
          label: product.label,
          summary: summary,
          isOn: toggleOn,
          hasChannels: canDrill,
          onRowTap: onRowTap,
          onToggleTap: toggleProduct,
          highlighted: highlighted,
          focusNode: focusNode,
        ),
      );
    }

    // Register the product count with the controller so the form's keyboard
    // navigation knows how many sub-items to step through.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.channelListController?.update(products.length, (
        context,
        subIndex,
      ) async {
        if (subIndex >= products.length) return;
        final product = products[subIndex];
        final scopeGranted = statusByKey[product.key]?.reason !=
            ProductStatusReason.scopeMissing;
        final productChannels = channelsByProduct[product.key] ?? [];
        if (scopeGranted && productChannels.length > 1) {
          _openProductChannels(context, product, productChannels, data);
          return;
        }
        // Single-/zero-channel or scope-missing: Enter toggles status. Scope
        // granted → toggle channels locally; scope-missing → stage re-auth.
        final anyOn = productChannels.any(
          (c) => _localSelectedChannels.contains('${c.providerKey}:${c.id}'),
        );
        setState(() {
          if (scopeGranted) {
            for (final ch in productChannels) {
              final key = '${ch.providerKey}:${ch.id}';
              if (anyOn) {
                _localSelectedChannels.remove(key);
              } else {
                _localSelectedChannels.add(key);
              }
            }
          } else if (_stagedProducts.contains(product.key)) {
            _stagedProducts.remove(product.key);
          } else {
            _stagedProducts.add(product.key);
          }
        });
        _notifyChanged();
      });
    });

    // ── Defensive orphan channels (no matching product key) ─────────────────
    final orphanRows = <Widget>[];
    if (orphanChannels.isNotEmpty) {
      orphanRows.addAll(
        _buildChannelTree(
          orphanChannels,
          focusCounter: focusCounter,
          reserveDisclosure: data.channels.any((c) => c.hasChildren),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Breathing room between the preceding Label field and the product
        // toggles.
        SizedBox(height: theme.spacing.md),
        ...accountRows,
        ...rows,
        ...orphanRows,
        if (rows.isNotEmpty || accountRows.isNotEmpty || orphanRows.isNotEmpty)
          SizedBox(height: theme.spacing.md),
      ],
    );
  }

  /// Opens a drill-down [FormModal] scoped to [product]'s channels.
  ///
  /// The drill-down renders the same [_buildChannelTree] / [_ChannelRow] rows
  /// but constrained to [productChannels]. Changes mutate [_localSelectedChannels]
  /// directly and call [_notifyChanged], so no result-return is needed.
  Future<void> _openProductChannels(
    BuildContext context,
    ProductInfo product,
    List<TwistChannel> productChannels,
    TwistIntegrations data,
  ) async {
    if (!context.mounted) return;

    final drillController = FormChannelListController();

    // Build the drill-down's items — mirrors _buildChannelTree but uses its
    // own focusCounter scoped to this modal's controller.
    Widget buildChannelList(BuildContext ctx) {
      // StatefulBuilder lets the channel list rebuild when a channel is toggled
      // (because _handleChannelTap calls setState on the parent widget, but the
      // drill-down modal has its own subtree; we trigger a local rebuild here
      // via innerSetState to keep the controller count current).
      return StatefulBuilder(
        builder: (ctx, innerSetState) {
          final drillFocusCounter = [0];
          final channelWidgets = _buildChannelTree(
            productChannels,
            focusCounter: drillFocusCounter,
            reserveDisclosure: productChannels.any((c) => c.hasChildren),
            controller: drillController,
            // A mouse tap mutates _localSelectedChannels via the parent's
            // setState, which doesn't rebuild this modal subtree; rebuild it
            // locally so the row's checked state updates immediately.
            onAfterTap: () {
              if (ctx.mounted) innerSetState(() {});
            },
          );

          // Update the drill controller count each build.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!ctx.mounted) return;
            final toggleable = _collectToggleableChannels(productChannels);
            drillController.update(toggleable.length, (
              innerCtx,
              subIdx,
            ) async {
              final toggleableNow = _collectToggleableChannels(productChannels);
              if (subIdx < toggleableNow.length) {
                _handleChannelTap(toggleableNow[subIdx]);
                innerSetState(() {});
              }
            });
          });

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: channelWidgets,
          );
        },
      );
    }

    final formData = FormData(
      title: product.label,
      groups: [
        StaticFormGroup(
          items: [
            FormChannelList(
              key: 'channels',
              controller: drillController,
              builder: buildChannelList,
            ),
          ],
        ),
      ],
    );

    final groups = await formData.list();
    if (!context.mounted) return;
    await FormModal(formData, groups: groups, rootContext: context).run(context);
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

    // The host form may render the account header at the top of the modal
    // (above the Label field) instead — in that case there's nothing to show
    // here, since a single-channel connector has no toggles.
    final accountRows = <Widget>[];
    if (widget.showAccounts) {
      for (final account in data.accounts) {
        accountRows.add(
          SourceAccountRow(
            account: account,
            logoUrl: widget.logoUrl,
            logoUrlDark: widget.logoUrlDark,
          ),
        );
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.channelListController?.update(0, (context, subIndex) async {});
    });

    if (accountRows.isEmpty) return const SizedBox.shrink();

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

/// The connected-account header: provider icon, account name/email, and a
/// "manage access" link. Rendered at the top of the setup/edit modal (above the
/// Label field) and inline by [SetupSourceWidget] for flows that keep accounts
/// next to their channels. Refreshing the channel list lives on the channel
/// section heading, not here.
class SourceAccountRow extends StatelessWidget {
  const SourceAccountRow({
    required this.account,
    this.isRemoved = false,
    this.logoUrl,
    this.logoUrlDark,
    super.key,
  });

  final TwistAccount account;
  final bool isRemoved;
  final String? logoUrl;
  final String? logoUrlDark;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final showEmail =
        account.email != null && account.email != account.displayName;

    // Slightly larger than a body glyph so the account reads as the screen's
    // subject rather than another list row.
    final iconSize = theme.iconSizes.lg;
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
                            fontWeight: FontWeight.w500,
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
      return LogoImage(url: url, size: size, fallback: providerIcon);
    }
    return providerIcon;
  }
}

/// Heading above the channel toggle list, e.g. "Teams to sync". Styled like the
/// form's field labels and carries the refresh-channels action on the right.
class _ChannelSectionHeader extends StatelessWidget {
  const _ChannelSectionHeader({
    required this.title,
    required this.onRefresh,
    required this.isRefreshing,
  });

  final String title;
  final VoidCallback? onRefresh;
  final bool isRefreshing;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      // Matches the form's section-heading rhythm: generous space above to
      // separate it from the Label field, tight below to hug its toggles.
      padding: EdgeInsets.only(
        left: theme.spacing.xl,
        right: theme.spacing.xl,
        top: theme.spacing.lg,
        bottom: theme.spacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              // Section heading: foreground + semibold, outranking the muted
              // field labels above. Mirrors FormGroup titles in form_modal.dart.
              style: theme.typography.sm.copyWith(
                color: theme.colors.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onRefresh != null)
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
    );
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
    this.reserveDisclosure = false,
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

  /// Whether to reserve a leading chevron gutter (true when any channel in the
  /// list nests, so all labels align in one column). Flat lists pass false so
  /// labels sit flush-left with the other form fields.
  final bool reserveDisclosure;
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
                left: theme.spacing.xl + (widget.depth * _channelIndent),
                right: theme.spacing.xl,
                top: theme.spacing.xs,
                bottom: theme.spacing.xs,
              ),
              child: Row(
                children: [
                  if (widget.reserveDisclosure) ...[
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.hasChildren ? widget.onExpandToggle : null,
                      child: SizedBox(
                        width: _disclosureWidth,
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
                    SizedBox(width: theme.spacing.sm),
                  ],
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
                  SizedBox(width: theme.spacing.md),
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
      case AuthProvider.todoist:
      case AuthProvider.airtable:
      case AuthProvider.monday:
      case AuthProvider.notion:
      case AuthProvider.discord:
      case AuthProvider.github:
      case AuthProvider.linkedin:
      case AuthProvider.whatsapp:
      case AuthProvider.instagram:
      case AuthProvider.apple:
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
        // The mark is monochrome: brand indigo on light, white on dark.
        return context.colour.brightness == Brightness.dark
            ? 'assets/linear_dark.svg'
            : 'assets/linear.svg';
      case AuthProvider.asana:
        return 'assets/asana.svg';
      case AuthProvider.hubspot:
        return 'assets/hubspot.svg';
      case AuthProvider.todoist:
        return 'assets/todoist.svg';
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
      case AuthProvider.linkedin:
        return 'assets/linkedin.svg';
      case AuthProvider.whatsapp:
        return 'assets/whatsapp.svg';
      case AuthProvider.instagram:
        return 'assets/instagram.svg';
      case AuthProvider.apple:
        // Black wordmark on light, white on dark.
        return context.colour.brightness == Brightness.dark
            ? 'assets/apple_dark.svg'
            : 'assets/apple.svg';
      default:
        return null;
    }
  }
}

/// A product-level row used in composite connections.
///
/// Renders: label + short summary on the left; optional `›` chevron for
/// products with channels; trailing toggle on the right.
///
/// The row is registered as a focusable sub-item of the enclosing
/// [FormChannelListController] and mirrors [_ChannelRow]'s focus/hover
/// mechanism exactly: [Focus] wrapping [MouseRegion] with highlight logic
/// driven by [highlighted] (keyboard) OR hover (mouse).
///
/// **Old `_CompositeProductRow`** was a [StatelessWidget] with [IgnorePointer]
/// on the toggle and no [Focus]/[MouseRegion] — it was not keyboard-focusable
/// and had no hover. Replaced by this stateful implementation.
///
/// **Enabled** products: label on the left, summary ("N labels") in muted
/// style, optional `›` chevron, and an on-switch on the right. Tapping the
/// row (or Enter) opens the channel drill-down when the product has channels.
///
/// **Not-enabled** products: label + "Not connected" summary, and an
/// off-switch that stages the product for re-auth on tap/Enter.
class _CompositeProductRow extends StatefulWidget {
  const _CompositeProductRow({
    required this.label,
    required this.summary,
    required this.isOn,
    required this.hasChannels,
    required this.onRowTap,
    required this.onToggleTap,
    this.highlighted = false,
    this.focusNode,
  });

  final String label;
  final String summary;
  final bool isOn;

  /// Whether this product has channels — controls rendering of the `›` chevron.
  final bool hasChannels;

  /// Called when the user taps the row body or presses Enter. May be null for
  /// products whose row tap is a no-op (e.g. enabled channelless products).
  final VoidCallback? onRowTap;

  /// Called when the user taps the trailing toggle directly.
  final VoidCallback onToggleTap;

  /// True when the form's keyboard navigator has highlighted this row.
  final bool highlighted;

  /// Focus node assigned by the [FormChannelListController]. Null when the
  /// row is not registered with a controller (e.g. in tests).
  final FocusNode? focusNode;

  @override
  State<_CompositeProductRow> createState() => _CompositeProductRowState();
}

class _CompositeProductRowState extends State<_CompositeProductRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final isTappable = widget.onRowTap != null;
    final isHighlighted = widget.highlighted || (_isHovered && isTappable);

    return Focus(
      focusNode: widget.focusNode,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isHighlighted
                ? theme.colors.foreground.withValues(alpha: 0.05)
                : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onRowTap,
            child: Padding(
              padding: EdgeInsets.only(
                left: theme.spacing.xl,
                right: theme.spacing.xl,
                top: theme.spacing.xs,
                bottom: theme.spacing.xs,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          widget.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            // One size larger than the inline summary so the
                            // product name reads as the row's title.
                            fontSize: theme.typography.md.fontSize,
                            color: theme.colors.foreground,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (widget.summary.isNotEmpty) ...[
                          SizedBox(width: theme.spacing.sm),
                          Flexible(
                            child: Text(
                              widget.summary,
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
                  if (widget.hasChannels) ...[
                    SizedBox(width: theme.spacing.xs),
                    Icon(
                      FontAwesomeIcons.chevronRight,
                      size: 10,
                      color: theme.colors.mutedForeground,
                    ),
                  ],
                  SizedBox(width: theme.spacing.md),
                  // The toggle is wrapped in its own GestureDetector so
                  // a direct tap toggles independently of the row-body tap
                  // (drill-in vs. quick toggle). IgnorePointer inside so the
                  // FSwitch itself does not intercept events.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onToggleTap,
                    child: IgnorePointer(
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

/// Per-account toggle for sequential auto-threading ("Group related messages
/// into conversations"). Mirrors {@link _AutoEnableNewChannelsRow}'s layout.
class _AutoThreadingRow extends StatefulWidget {
  const _AutoThreadingRow({
    required this.isOn,
    required this.onToggle,
    required this.showAccountLabel,
    required this.accountLabel,
    required this.reserveDisclosure,
  });

  final bool isOn;
  final VoidCallback onToggle;
  final bool showAccountLabel;
  final String accountLabel;

  /// Mirrors the channel rows' leading gutter so this row's title aligns with
  /// the channel labels above it.
  final bool reserveDisclosure;

  @override
  State<_AutoThreadingRow> createState() => _AutoThreadingRowState();
}

class _AutoThreadingRowState extends State<_AutoThreadingRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final title = widget.showAccountLabel
        ? 'Group related messages · ${widget.accountLabel}'
        : 'Group related messages';

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
            // Share the channel rows' tight vertical rhythm so these settings
            // read as part of the same "<entity> to sync" block, not detached.
            padding: EdgeInsets.only(
              left: theme.spacing.xl,
              right: theme.spacing.xl,
              top: theme.spacing.xs,
              bottom: theme.spacing.xs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (widget.reserveDisclosure)
                  SizedBox(width: _disclosureWidth + theme.spacing.sm),
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
                        'Fold a conversation that arrives as separate messages '
                        'into one thread.',
                        style: TextStyle(
                          fontSize: theme.typography.xs.fontSize,
                          color: theme.colors.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: theme.spacing.md),
                IgnorePointer(
                  child: SizedBox(
                    width: 32,
                    height: 20,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: FSwitch(value: widget.isOn, onChange: (_) {}),
                    ),
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

class _AutoEnableNewChannelsRow extends StatefulWidget {
  const _AutoEnableNewChannelsRow({
    required this.noun,
    required this.isOn,
    required this.onToggle,
    required this.showAccountLabel,
    required this.accountLabel,
    required this.reserveDisclosure,
  });

  /// The connector's word for its channels (folders, projects, …). Drives the
  /// row's title and description copy.
  final ChannelNoun noun;
  final bool isOn;
  final VoidCallback onToggle;

  /// When the modal shows multiple accounts of the same connector, append the
  /// account label to the title so the user can tell the toggles apart.
  final bool showAccountLabel;
  final String accountLabel;

  /// Mirrors the channel rows' leading gutter so this row's title aligns with
  /// the channel labels above it.
  final bool reserveDisclosure;

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
        ? 'Sync new ${widget.noun.plural} · ${widget.accountLabel}'
        : 'Sync new ${widget.noun.plural}';

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
            // Share the channel rows' tight vertical rhythm so these settings
            // read as part of the same "<entity> to sync" block, not detached.
            padding: EdgeInsets.only(
              left: theme.spacing.xl,
              right: theme.spacing.xl,
              top: theme.spacing.xs,
              bottom: theme.spacing.xs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (widget.reserveDisclosure)
                  SizedBox(width: _disclosureWidth + theme.spacing.sm),
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
                        'When a new ${widget.noun.singular} is added, '
                        'enable it automatically.',
                        style: TextStyle(
                          fontSize: theme.typography.xs.fontSize,
                          color: theme.colors.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: theme.spacing.md),
                IgnorePointer(
                  child: SizedBox(
                    width: 32,
                    height: 20,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: FSwitch(value: widget.isOn, onChange: (_) {}),
                    ),
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

// ============================================================================
// Composite re-auth CTA
// ============================================================================

/// Renders a single "Continue with Google" [AuthButton] for composite
/// connections that have one or more products staged for re-auth.
///
/// When [stagedGroupIds] is non-empty, the widget shows a reconnect prompt
/// and an [AuthButton.connect] whose [enabledScopeGroups] is the union of
/// [grantedGroupIds] ∪ [stagedGroupIds], so the OAuth consent screen
/// requests all currently-granted permissions plus the new ones in one shot.
///
/// When [stagedGroupIds] is empty the widget renders nothing — used by
/// [EditSource._buildForm] to hide the reauth CTA when no products are staged.
///
/// This widget is kept in `setup_source.dart` (rather than `twist.dart`) so
/// it can be unit-tested without pulling in the full EditSource command
/// infrastructure.
class CompositeReauthWidget extends StatefulWidget {
  const CompositeReauthWidget({
    required this.provider,
    required this.twistInstanceId,
    required this.grantedGroupIds,
    required this.stagedGroupIds,
    required this.onSuccess,
    this.accountHint,
    this.forReauth = false,
    super.key,
  });

  final TwistProvider provider;
  final String twistInstanceId;

  /// Scope group ids for products already granted (enabled) — derived from
  /// the current [productStatus] entries whose [enabled] flag is true.
  final Set<String> grantedGroupIds;

  /// Scope group ids for products the user has staged for re-auth — derived
  /// from [IntegrationChanges.stagedProducts] mapped through
  /// [TwistIntegrations.products].
  final Set<String> stagedGroupIds;

  /// Passed to [AuthButton.connect] as the login_hint so Google can skip the
  /// account-chooser when possible.
  final String? accountHint;

  /// Called after a successful OAuth flow — the caller should pull fresh
  /// connection state and refresh the form.
  final Future<void> Function() onSuccess;

  /// When true, the caller (needs-reauth flow) already renders its own
  /// "Reconnect … to resume syncing." message above this widget, so we omit
  /// the redundant "Reconnect to enable new products." line and show only the
  /// account hint. When false (product-setup flow, where new products are
  /// being staged) we show the full "enable new products" prompt.
  final bool forReauth;

  @override
  State<CompositeReauthWidget> createState() => CompositeReauthWidgetState();
}

class CompositeReauthWidgetState extends State<CompositeReauthWidget> {
  /// The union of granted and staged scope group ids — passed to
  /// [AuthButton.connect] as [enabledScopeGroups]. Exposed for testing.
  Set<String> get computedScopeGroupIds => {
        ...widget.grantedGroupIds,
        ...widget.stagedGroupIds,
      };

  @override
  Widget build(BuildContext context) {
    if (widget.stagedGroupIds.isEmpty) return const SizedBox.shrink();

    final theme = context.theme;
    final union = computedScopeGroupIds;

    // In the reauth flow the parent already shows a "Reconnect … to resume
    // syncing." message, so we drop the redundant reconnect sentence and only
    // surface the account hint (if any). In the product-setup flow we prompt
    // to enable the newly staged products.
    final headerText = widget.forReauth
        ? (widget.accountHint != null
            ? 'Sign in as ${widget.accountHint}.'
            : null)
        : (widget.accountHint != null
            ? 'Reconnect to enable new products. Sign in as ${widget.accountHint}.'
            : 'Reconnect to enable new products.');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (headerText != null)
          Padding(
            padding: EdgeInsets.only(
              left: theme.spacing.xl,
              right: theme.spacing.xl,
              top: theme.spacing.md,
              bottom: theme.spacing.sm,
            ),
            child: Text(
              headerText,
              style: theme.typography.sm.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.only(
            left: theme.spacing.xl,
            right: theme.spacing.xl,
            bottom: theme.spacing.lg,
          ),
          // SizedBox(width: double.infinity) forces the button to fill the
          // available horizontal space, matching product_setup.dart's pattern.
          child: SizedBox(
            width: double.infinity,
            child: AuthButton.connect(
              provider: widget.provider.provider,
              scopes: widget.provider.scopes,
              twistInstanceId: widget.twistInstanceId,
              enabledScopeGroups: union.isNotEmpty ? union.toList() : null,
              accountHint: widget.accountHint,
              onSuccess: widget.onSuccess,
            ),
          ),
        ),
      ],
    );
  }
}

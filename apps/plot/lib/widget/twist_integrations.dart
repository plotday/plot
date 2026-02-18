import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/api/twist_api.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/spinner.dart';
import 'package:plot/widget/toast.dart';
import 'logging.dart';

/// Selected syncable for the setup flow.
class SelectedSyncable {
  final String provider;
  final String syncableId;

  const SelectedSyncable({required this.provider, required this.syncableId});
}

/// Tracks local integration changes (syncable toggles + account removals)
/// that are deferred until Save/Add.
class IntegrationChanges {
  final Set<String> selectedSyncables; // "provider:syncableId" keys
  final Set<String> removedAccounts; // "provider:actorId" keys

  const IntegrationChanges({
    this.selectedSyncables = const {},
    this.removedAccounts = const {},
  });
}

/// Displays integration accounts and syncable resources for a twist.
/// Used in both the setup and edit twist modals.
class TwistIntegrationsWidget extends StatefulWidget {
  const TwistIntegrationsWidget({
    required this.priorityTwistId,
    this.setupMode = false,
    this.initialData,
    this.refreshNotifier,
    this.onChanged,
    super.key,
  });

  final String priorityTwistId;

  /// When true, account removal calls the API immediately (for drafts).
  /// When false (edit mode), account removal is deferred until Save.
  final bool setupMode;

  /// Pre-loaded integrations data to avoid a loading spinner on open.
  final TwistIntegrations? initialData;

  /// When notified, triggers a reload of integrations data.
  final ValueNotifier<int>? refreshNotifier;

  /// Called when local integration state changes (syncables or accounts).
  final ValueChanged<IntegrationChanges>? onChanged;

  @override
  State<TwistIntegrationsWidget> createState() =>
      _TwistIntegrationsWidgetState();
}

class _TwistIntegrationsWidgetState extends State<TwistIntegrationsWidget> {
  TwistIntegrations? _data;
  bool _isLoading = true;
  String? _error;

  /// Locally tracked selected syncable keys ("provider:syncableId").
  final Set<String> _localSelectedSyncables = {};

  /// Soft-removed account keys ("provider:actorId") — edit mode only.
  final Set<String> _removedAccounts = {};

  /// Snapshot of selected syncables per removed account for undo.
  final Map<String, Set<String>> _removedAccountSyncableSnapshot = {};

  /// Whether we've seeded _localSelectedSyncables from server state (edit mode).
  bool _initializedFromServer = false;

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

  /// Seed local selected syncables from server enabled state (edit mode only).
  void _seedLocalState(TwistIntegrations data) {
    if (!widget.setupMode && !_initializedFromServer) {
      for (final syncable in data.syncables) {
        if (syncable.enabled) {
          _localSelectedSyncables.add(
            '${syncable.provider.name}:${syncable.id}',
          );
        }
      }
      _initializedFromServer = true;
    }
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

  /// Immediately remove an account via API (setup mode for drafts).
  Future<void> _removeAccountImmediate(TwistAccount account) async {
    try {
      await TwistApi.removeIntegration(
        priorityTwistId: widget.priorityTwistId,
        provider: account.provider.name,
        actorId: account.actorId,
      );
      await _loadIntegrations();
    } catch (e, t) {
      log.warning('Failed to remove integration', e, t);
      if (mounted) {
        context.showToast(
          message: 'Failed to remove account. Please try again.',
          isError: true,
        );
      }
    }
  }

  /// Soft-remove an account locally (edit mode — deferred until Save).
  void _softRemoveAccount(TwistAccount account) {
    final accountKey = '${account.provider.name}:${account.actorId}';

    // Snapshot the currently selected syncables for this account's provider
    // so we can restore them on undo.
    final providerSyncables =
        _data?.syncables
            .where((s) => s.provider == account.provider)
            .map((s) => '${s.provider.name}:${s.id}')
            .where(_localSelectedSyncables.contains)
            .toSet() ??
        {};

    setState(() {
      _removedAccounts.add(accountKey);
      _removedAccountSyncableSnapshot[accountKey] = providerSyncables;
    });
    _notifyChanged();
  }

  /// Undo a soft-removed account (edit mode).
  void _undoRemoveAccount(String accountKey) {
    setState(() {
      _removedAccounts.remove(accountKey);
      // Restore syncable snapshot
      final snapshot = _removedAccountSyncableSnapshot.remove(accountKey);
      if (snapshot != null) {
        _localSelectedSyncables.addAll(snapshot);
      }
    });
    _notifyChanged();
  }

  void _toggleSyncable(TwistSyncable syncable) {
    final key = '${syncable.provider.name}:${syncable.id}';
    setState(() {
      if (_localSelectedSyncables.contains(key)) {
        _localSelectedSyncables.remove(key);
      } else {
        _localSelectedSyncables.add(key);
      }
    });
    _notifyChanged();
  }

  void _notifyChanged() {
    if (widget.onChanged == null) return;
    widget.onChanged!(
      IntegrationChanges(
        selectedSyncables: Set.of(_localSelectedSyncables),
        removedAccounts: Set.of(_removedAccounts),
      ),
    );
  }

  Widget _buildSyncableRow(TwistSyncable syncable) {
    final key = '${syncable.provider.name}:${syncable.id}';
    return _SyncableRow(
      syncable: syncable,
      isChecked: _localSelectedSyncables.contains(key),
      canToggle: widget.setupMode || syncable.currentUserHasAccess,
      onToggle: () => _toggleSyncable(syncable),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Padding(
        padding: widgetPadding,
        child: const Center(child: Spinner()),
      );
    }

    if (_error != null) {
      return Padding(
        padding: widgetPadding,
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

    // Group syncables by provider to display under matching accounts
    final syncablesByProvider = <AuthProvider, List<TwistSyncable>>{};
    for (final syncable in data.syncables) {
      syncablesByProvider
          .putIfAbsent(syncable.provider, () => [])
          .add(syncable);
    }

    // Build account rows with syncables grouped after the last account
    // of each provider
    final accountWidgets = <Widget>[];
    final shownProviders = <AuthProvider>{};
    for (int i = 0; i < data.accounts.length; i++) {
      final account = data.accounts[i];
      final accountKey = '${account.provider.name}:${account.actorId}';
      final isRemoved = _removedAccounts.contains(accountKey);

      accountWidgets.add(
        _AccountRow(
          account: account,
          isRemoved: isRemoved,
          onRemove: () => widget.setupMode
              ? _removeAccountImmediate(account)
              : _softRemoveAccount(account),
          onUndo: () => _undoRemoveAccount(accountKey),
        ),
      );

      // Show syncables after the last account of each provider
      // Hide syncables for providers where all accounts are removed
      final isLast = !data.accounts
          .skip(i + 1)
          .any((a) => a.provider == account.provider);
      if (isLast &&
          !shownProviders.contains(account.provider) &&
          !fullyRemovedProviders.contains(account.provider) &&
          syncablesByProvider.containsKey(account.provider)) {
        shownProviders.add(account.provider);
        for (final syncable in syncablesByProvider[account.provider]!) {
          accountWidgets.add(_buildSyncableRow(syncable));
        }
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: widgetPaddingSm,
          child: Text(
            'Integrations',
            style: context.theme.typography.sm.copyWith(
              fontWeight: FontWeight.w600,
              color: context.theme.plotColors.muted,
            ),
          ),
        ),
        ...accountWidgets,
        if (accountWidgets.isNotEmpty)
          SizedBox(height: context.theme.spacing.md),
      ],
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.onRemove,
    this.isRemoved = false,
    this.onUndo,
  });

  final TwistAccount account;
  final VoidCallback onRemove;
  final bool isRemoved;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    // Show email as subtitle if it differs from displayName
    final showEmail =
        account.email != null && account.email != account.displayName;

    final iconSize = theme.iconSizes.base;

    return Opacity(
      opacity: isRemoved ? 0.4 : 1.0,
      child: Padding(
        padding: EdgeInsets.only(left: 20, right: 4, bottom: theme.spacing.md),
        child: Row(
          children: [
            _ProviderIcon(provider: account.provider, size: iconSize),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      account.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: theme.typography.base.fontSize,
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
                          fontSize: theme.typography.base.fontSize,
                          color: theme.colors.mutedForeground,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            FButton.icon(
              onPress: isRemoved ? onUndo : onRemove,
              style: FButtonStyle.ghost(),
              child: Icon(
                isRemoved ? FontAwesomeIcons.plus : FontAwesomeIcons.xmark,
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

class _SyncableRow extends StatefulWidget {
  const _SyncableRow({
    required this.syncable,
    required this.isChecked,
    required this.canToggle,
    required this.onToggle,
  });

  final TwistSyncable syncable;
  final bool isChecked;
  final bool canToggle;
  final VoidCallback onToggle;

  @override
  State<_SyncableRow> createState() => _SyncableRowState();
}

class _SyncableRowState extends State<_SyncableRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    // Indented to align under account name (20 left + 16 icon + 12 gap = 48)
    return MouseRegion(
      cursor: widget.canToggle
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.canToggle ? widget.onToggle : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _isHovered && widget.canToggle
                ? theme.colors.foreground.withValues(alpha: 0.05)
                : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: EdgeInsets.only(
              left: theme.spacing.xxl,
              right: theme.spacing.sm,
              bottom: theme.spacing.sm,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 42,
                  height: 25,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: FSwitch(
                      value: widget.isChecked,
                      onChange: widget.canToggle
                          ? (_) => widget.onToggle()
                          : null,
                      enabled: widget.canToggle,
                    ),
                  ),
                ),
                SizedBox(width: theme.spacing.md),
                Expanded(
                  child: Text(
                    widget.syncable.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: theme.typography.base.fontSize,
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
    );
  }
}

class _ProviderIcon extends StatelessWidget {
  final AuthProvider provider;
  final double size;

  const _ProviderIcon({required this.provider, required this.size});

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

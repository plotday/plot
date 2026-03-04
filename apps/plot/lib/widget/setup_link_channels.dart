import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/api/twist_api.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/spinner.dart';
import 'logging.dart';

/// Tracks selected link channels for a twist.
class LinkChannelSelection {
  final List<LinkChannelEntry> entries;

  const LinkChannelSelection({this.entries = const []});
}

/// A single link channel selection entry.
class LinkChannelEntry {
  final String sourcePriorityTwistId;
  final String channelId;
  final bool enabled;

  const LinkChannelEntry({
    required this.sourcePriorityTwistId,
    required this.channelId,
    required this.enabled,
  });

  Map<String, dynamic> toJson() => {
        'sourcePriorityTwistId': sourcePriorityTwistId,
        'channelId': channelId,
        'enabled': enabled,
      };
}

/// Displays available source channels for link observation.
/// Used in both the setup and edit twist modals.
class SetupLinkChannelsWidget extends StatefulWidget {
  const SetupLinkChannelsWidget({
    required this.priorityTwistId,
    this.priorityId,
    this.priorityNotifier,
    this.setupMode = false,
    this.onChanged,
    super.key,
  });

  final String priorityTwistId;

  /// Priority ID used to filter available channels.
  final String? priorityId;

  /// When provided, the widget listens for priority changes and reloads.
  final ValueNotifier<String?>? priorityNotifier;

  /// In setup mode, skip fetching existing link channels (draft has none).
  final bool setupMode;

  final ValueChanged<LinkChannelSelection>? onChanged;

  @override
  State<SetupLinkChannelsWidget> createState() =>
      _SetupLinkChannelsWidgetState();
}

class _SetupLinkChannelsWidgetState extends State<SetupLinkChannelsWidget> {
  List<LinkChannel>? _availableChannels;
  bool _isLoading = true;
  String? _error;

  /// Locally tracked enabled state per channel key.
  final Map<String, bool> _localEnabled = {};

  @override
  void initState() {
    super.initState();
    widget.priorityNotifier?.addListener(_onPriorityChanged);
    _load();
  }

  @override
  void dispose() {
    widget.priorityNotifier?.removeListener(_onPriorityChanged);
    super.dispose();
  }

  void _onPriorityChanged() {
    _localEnabled.clear();
    _notifyChanged();
    _load();
  }

  /// The effective priority ID: from notifier (if present) or direct param.
  String? get _effectivePriorityId =>
      widget.priorityNotifier?.value ?? widget.priorityId;

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final available = await TwistApi.getAvailableLinkChannels(
        widget.priorityTwistId,
        priorityId: _effectivePriorityId,
      );

      List<ConnectedLinkChannel>? connected;
      if (!widget.setupMode) {
        connected = await TwistApi.getLinkChannels(widget.priorityTwistId);
      }

      if (mounted) {
        // Seed local state from connected channels (edit mode only)
        if (connected != null) {
          for (final ch in connected) {
            final key = '${ch.sourcePriorityTwistId}:${ch.channelId}';
            _localEnabled[key] = ch.enabled;
          }
        }

        setState(() {
          _availableChannels = available;
          _isLoading = false;
        });
      }
    } catch (e, t) {
      log.warning('Failed to load link channels', e, t);
      if (mounted) {
        setState(() {
          _error = 'Failed to load source channels';
          _isLoading = false;
        });
      }
    }
  }

  void _handleToggle(LinkChannel channel) {
    final key = '${channel.sourcePriorityTwistId}:${channel.channelId}';
    final isEnabled = _localEnabled[key] ?? false;

    setState(() {
      _localEnabled[key] = !isEnabled;
    });
    _notifyChanged();
  }

  void _notifyChanged() {
    if (widget.onChanged == null) return;

    final entries = <LinkChannelEntry>[];
    for (final entry in _localEnabled.entries) {
      final parts = entry.key.split(':');
      final sourcePriorityTwistId = parts[0];
      final channelId = parts.sublist(1).join(':');
      entries.add(LinkChannelEntry(
        sourcePriorityTwistId: sourcePriorityTwistId,
        channelId: channelId,
        enabled: entry.value,
      ));
    }

    widget.onChanged!(LinkChannelSelection(entries: entries));
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

    final channels = _availableChannels;
    if (channels == null || channels.isEmpty) {
      return Padding(
        padding: context.theme.spacing.padding,
        child: Text(
          'No source channels available. Add a source to this priority first.',
          style: TextStyle(
            fontSize: context.theme.typography.sm.fontSize,
            color: context.theme.colors.mutedForeground,
          ),
        ),
      );
    }

    // Group channels by source instance (per-account)
    final grouped = <String, List<LinkChannel>>{};
    for (final channel in channels) {
      grouped
          .putIfAbsent(channel.sourcePriorityTwistId, () => [])
          .add(channel);
    }

    final sections = <Widget>[];
    for (final entry in grouped.entries) {
      final firstChannel = entry.value.first;
      final headerParts = [firstChannel.sourceName];
      if (firstChannel.accountName != null) {
        headerParts.add(firstChannel.accountName!);
      }

      // Section header
      sections.add(
        _SourceHeader(name: headerParts.join(' \u00b7 ')),
      );
      // Channel rows
      for (final channel in entry.value) {
        final key =
            '${channel.sourcePriorityTwistId}:${channel.channelId}';
        final isEnabled = _localEnabled[key] ?? false;
        sections.add(_LinkChannelRow(
          channel: channel,
          isChecked: isEnabled,
          onToggle: () => _handleToggle(channel),
        ));
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...sections,
        SizedBox(height: context.theme.spacing.md),
      ],
    );
  }
}

class _SourceHeader extends StatelessWidget {
  const _SourceHeader({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: EdgeInsets.only(
        left: theme.spacing.lg,
        top: theme.spacing.md,
        bottom: theme.spacing.xs,
      ),
      child: Text(
        name,
        style: theme.typography.sm.copyWith(
          color: theme.colors.mutedForeground,
        ),
      ),
    );
  }
}

class _LinkChannelRow extends StatefulWidget {
  const _LinkChannelRow({
    required this.channel,
    required this.isChecked,
    required this.onToggle,
  });

  final LinkChannel channel;
  final bool isChecked;
  final VoidCallback onToggle;

  @override
  State<_LinkChannelRow> createState() => _LinkChannelRowState();
}

class _LinkChannelRowState extends State<_LinkChannelRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
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
              left: theme.spacing.lg,
              right: theme.spacing.lg,
              bottom: theme.spacing.sm,
            ),
            child: Row(
              children: [
                IgnorePointer(
                  child: SizedBox(
                    width: 32,
                    height: 20,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: FSwitch(
                        value: widget.isChecked,
                        onChange: (_) {},
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
                      color: theme.colors.foreground,
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

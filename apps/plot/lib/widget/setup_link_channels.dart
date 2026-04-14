import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/api/twist_api.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/form.dart';
import 'package:plot/widget/spinner.dart';
import 'logging.dart';

/// Tracks selected link channels for a twist.
class LinkChannelSelection {
  final List<LinkChannelEntry> entries;

  const LinkChannelSelection({this.entries = const []});
}

/// A single link channel selection entry.
class LinkChannelEntry {
  final String sourceTwistInstanceId;
  final String channelId;
  final bool enabled;

  const LinkChannelEntry({
    required this.sourceTwistInstanceId,
    required this.channelId,
    required this.enabled,
  });

  Map<String, dynamic> toJson() => {
        'sourceTwistInstanceId': sourceTwistInstanceId,
        'channelId': channelId,
        'enabled': enabled,
      };
}

/// Displays available source channels for link observation.
/// Used in both the setup and edit twist modals.
class SetupLinkChannelsWidget extends StatefulWidget {
  const SetupLinkChannelsWidget({
    required this.twistInstanceId,
    this.setupMode = false,
    this.onChanged,
    this.channelListController,
    super.key,
  });

  final String twistInstanceId;

  /// In setup mode, skip fetching existing link channels (draft has none).
  final bool setupMode;

  final ValueChanged<LinkChannelSelection>? onChanged;

  /// Controller for keyboard navigation integration with FormChannelList.
  final FormChannelListController? channelListController;

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
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final available = await TwistApi.getAvailableLinkChannels(
        widget.twistInstanceId,
      );

      List<ConnectedLinkChannel>? connected;
      if (!widget.setupMode) {
        connected = await TwistApi.getLinkChannels(widget.twistInstanceId);
      }

      if (mounted) {
        // Seed local state from connected channels (edit mode only)
        if (connected != null) {
          for (final ch in connected) {
            final key = '${ch.sourceTwistInstanceId}:${ch.channelId}';
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
    final key = '${channel.sourceTwistInstanceId}:${channel.channelId}';
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
      final sourceTwistInstanceId = parts[0];
      final channelId = parts.sublist(1).join(':');
      entries.add(LinkChannelEntry(
        sourceTwistInstanceId: sourceTwistInstanceId,
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
          'No source channels available. Connect a source first.',
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
          .putIfAbsent(channel.sourceTwistInstanceId, () => [])
          .add(channel);
    }

    // Collect all channels in display order for the controller
    final allChannels = <LinkChannel>[];
    for (final entry in grouped.entries) {
      allChannels.addAll(entry.value);
    }

    // Update controller with current focusable count and activator
    final controller = widget.channelListController;
    controller?.update(
      allChannels.length,
      (context, subIndex) async {
        if (subIndex < allChannels.length) {
          _handleToggle(allChannels[subIndex]);
        }
      },
    );

    int focusIndex = 0;
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
            '${channel.sourceTwistInstanceId}:${channel.channelId}';
        final isEnabled = _localEnabled[key] ?? false;
        final highlighted = controller != null &&
            controller.highlightedSubIndex == focusIndex;
        final focusNode = controller != null &&
                focusIndex < controller.focusNodes.length
            ? controller.focusNodes[focusIndex]
            : null;
        sections.add(_LinkChannelRow(
          channel: channel,
          isChecked: isEnabled,
          onToggle: () => _handleToggle(channel),
          highlighted: highlighted,
          focusNode: focusNode,
        ));
        focusIndex++;
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
    this.highlighted = false,
    this.focusNode,
  });

  final LinkChannel channel;
  final bool isChecked;
  final VoidCallback onToggle;
  final bool highlighted;
  final FocusNode? focusNode;

  @override
  State<_LinkChannelRow> createState() => _LinkChannelRowState();
}

class _LinkChannelRowState extends State<_LinkChannelRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final isHighlighted = widget.highlighted || _isHovered;

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isHighlighted
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

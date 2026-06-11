import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/analytics/conventions.dart';
import 'package:plot/api/broadcast.dart';
import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/sidebar_leading.dart';
import 'package:plot/widget/pulsing_icon.dart';

/// Status tile shown above the account tile in the priorities panel.
///
/// Resolves a single state in priority order:
///   1. Offline
///   2. One or more connections need reconnecting
///   3. One or more connections are syncing
///   4. Otherwise: prompt to add a connection
///
/// All states except offline open the manage-connections modal on tap.
class ConnectionStatusTile extends StatelessWidget {
  const ConnectionStatusTile({super.key});

  /// Transparent highlight so the hover effect matches the header icon
  /// buttons — only the text/icon color shifts, no rounded background pill.
  static const _transparentHighlight = Color(0x00000000);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: BroadcastClient.instance.connectionState,
      builder: (context, online, _) {
        return StreamBuilder<List<TwistConnectionRow>>(
          stream: TwistConnection.watchAll(),
          initialData: const [],
          builder: (context, connSnap) {
            return StreamBuilder<List<TwistInstance>>(
              stream: TwistInstance.watch(),
              initialData: const [],
              builder: (context, instSnap) {
                return _buildTile(
                  context,
                  online: online,
                  connections: connSnap.data ?? const [],
                  instances: instSnap.data ?? const [],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildTile(
    BuildContext context, {
    required bool online,
    required List<TwistConnectionRow> connections,
    required List<TwistInstance> instances,
  }) {
    // Match the resting priority tiles' weight so the priority frame reads
    // as a single typographic family (sm / w500 / plotColors.muted).
    final textStyle = context.theme.typography.sm.copyWith(
      fontWeight: FontWeight.w500,
    );

    if (!online) {
      return ListTile(
        title: 'Offline',
        leadingBuilder: _leadingIcon(context, PlotIcon.plugCircleXmark),
        textStyle: textStyle,
        muted: true,
        noHoverHighlight: true,
      );
    }

    final reauthNeeded = _names(
      connections.where((c) => c.needsReauth),
      instances,
    );
    if (reauthNeeded.isNotEmpty) {
      return ListTile(
        title: 'Reconnect ${reauthNeeded.join(', ')}',
        textStyle: textStyle.copyWith(color: context.theme.colors.destructive),
        highlightColor: _transparentHighlight,
        leadingBuilder: _leadingWidget(
          context,
          PlotIcon.plugCircleExclamation,
          Icon(
            PlotIcon.plugCircleExclamation,
            size: context.theme.iconSizes.base,
            color: context.theme.colors.destructive,
          ),
        ),
        command: _OpenManageConnections(
          title: 'Reconnect ${reauthNeeded.join(', ')}',
        ),
      );
    }

    final syncing = _names(
      connections.where((c) => c.initialSyncing),
      instances,
    );
    if (syncing.isNotEmpty) {
      final tile = ListTile(
        title: 'Syncing ${syncing.join(', ')}',
        textStyle: textStyle,
        muted: true,
        highlightColor: _transparentHighlight,
        leadingBuilder: _leadingWidget(
          context,
          PlotIcon.plugCircleBolt,
          PulsingIcon(
            icon: PlotIcon.plugCircleBolt,
            size: context.theme.iconSizes.base,
            primaryColor: context.theme.colors.primary,
          ),
        ),
        command: _OpenManageConnections(title: 'Syncing ${syncing.join(', ')}'),
      );
      if (syncing.length > 1) {
        return FTooltip(
          tipBuilder: (context, controller) => Text(syncing.join('\n')),
          child: tile,
        );
      }
      return tile;
    }

    final hasConnections = connections.isNotEmpty;
    final title = hasConnections ? 'Connections' : 'Add connection';
    return ListTile(
      title: title,
      leadingBuilder: _leadingIcon(
        context,
        hasConnections ? PlotIcon.connection : PlotIcon.plugCirclePlus,
      ),
      textStyle: textStyle,
      muted: true,
      highlightColor: _transparentHighlight,
      command: _OpenManageConnections(title: title),
    );
  }

  /// Builds an icon in the shared sidebar leading slot (see [sidebarLeading]).
  /// The icon color flips muted → foreground on hover, matching `muted: true`.
  Widget? Function(bool, bool) _leadingIcon(
    BuildContext context,
    IconData icon,
  ) => (isHovered, hasFocus) {
    final highlighted = isHovered || hasFocus;
    return _leadingWidget(
      context,
      icon,
      Icon(
        icon,
        size: context.theme.iconSizes.base,
        color: highlighted
            ? context.theme.colors.foreground
            : context.theme.plotColors.muted,
      ),
    )(isHovered, hasFocus);
  };

  Widget? Function(bool, bool) _leadingWidget(
    BuildContext context,
    IconData icon,
    Widget child,
  ) {
    // FontAwesome plug-circle-* glyphs are 640×512 — they paint wider than
    // the 16px square the Icon widget reserves and overflow to the right,
    // crowding the label. Shift the icon left by half the overflow so its
    // visual centre matches a standard square icon, keeping the label aligned
    // with neighbouring priority tiles.
    final isWidePlug =
        icon == PlotIcon.plugCirclePlus ||
        icon == PlotIcon.plugCircleXmark ||
        icon == PlotIcon.plugCircleExclamation ||
        icon == PlotIcon.plugCircleBolt;
    final base = context.theme.iconSizes.base;
    final shifted = isWidePlug
        ? Transform.translate(offset: Offset(-base * 0.125, 0), child: child)
        : child;
    return (isHovered, hasFocus) => sidebarLeading(context, shifted);
  }

  /// Resolve display names for the twist instances referenced by the supplied
  /// connection rows. Multiple connections on the same instance dedupe, and
  /// rows whose instance hasn't synced yet are skipped.
  List<String> _names(
    Iterable<TwistConnectionRow> rows,
    List<TwistInstance> instances,
  ) {
    final byId = {for (final i in instances) i.id: i};
    final seen = <TwistInstanceId>{};
    final names = <String>[];
    for (final row in rows) {
      if (!seen.add(row.twistInstanceId)) continue;
      final instance = byId[row.twistInstanceId];
      if (instance == null) continue;
      names.add(instance.displayName(allInstances: instances));
    }
    return names;
  }
}

/// Internal command that opens the manage-connections modal when the tile is
/// tapped. The host tile renders the icon via `leadingBuilder`, so this
/// command no longer needs to provide one.
class _OpenManageConnections extends Command {
  _OpenManageConnections({required super.title})
    : super(eventObject: EventObject.twist, eventAction: EventAction.opened);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Prefetch so the modal opens with content already populated. The host
    // ListTile shows its spinner during this load — far more legible than a
    // blank modal that just contains a spinner.
    await ManageConnections.prewarm();
    if (!context.mounted) return const CommandSkipped();
    return ManageConnections(keepCache: true).run(context);
  }
}

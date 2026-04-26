import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/analytics/conventions.dart';
import 'package:plot/api/broadcast.dart';
import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/list_tile.dart';
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
    final textStyle = context.theme.typography.sm;

    if (!online) {
      return ListTile(
        title: 'Offline',
        icon: PlotIcon.plugCircleXmark,
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
        command: _OpenManageConnections(
          title: 'Reconnect ${reauthNeeded.join(', ')}',
          iconBuilder: (c) => Icon(
            PlotIcon.plugCircleExclamation,
            size: c.theme.iconSizes.base,
            color: c.theme.colors.destructive,
          ),
        ),
      );
    }

    final syncing = _names(
      connections.where((c) => c.initialSyncing),
      instances,
    );
    if (syncing.isNotEmpty) {
      return ListTile(
        title: 'Syncing ${syncing.join(', ')}',
        textStyle: textStyle,
        muted: true,
        command: _OpenManageConnections(
          title: 'Syncing ${syncing.join(', ')}',
          iconBuilder: (c) => PulsingIcon(
            icon: PlotIcon.plugCircleBolt,
            size: c.theme.iconSizes.base,
            primaryColor: c.theme.colors.primary,
          ),
        ),
      );
    }

    return ListTile(
      title: 'Add connection',
      icon: PlotIcon.plugCirclePlus,
      textStyle: textStyle,
      muted: true,
      command: _OpenManageConnections(title: 'Add connection'),
    );
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
/// tapped. Optionally renders a custom icon widget so the same tap target can
/// surface a destructive or pulsing icon.
class _OpenManageConnections extends Command {
  _OpenManageConnections({required super.title, this.iconBuilder})
    : super(eventObject: EventObject.twist, eventAction: EventAction.opened);

  final Widget Function(BuildContext context)? iconBuilder;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) =>
      iconBuilder?.call(context);

  @override
  Future<CommandReturn> run(BuildContext context) =>
      ManageConnections().run(context);
}

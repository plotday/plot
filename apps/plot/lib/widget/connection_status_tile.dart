import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/analytics/conventions.dart';
import 'package:plot/api/broadcast.dart';
import 'package:plot/command/command.dart';
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

  // TODO(connection-signals): wire to a real per-connection stream once the
  // server-side `needs_reauth` flag lands on twist_instance. The stream should
  // emit display names for connections requiring reauthorization.
  static Stream<List<String>> _reauthNeededStream() =>
      Stream<List<String>>.value(const []);

  // TODO(connection-signals): wire to a real per-connection stream once the
  // server pushes per-connection sync status. The stream should emit display
  // names for connections currently syncing.
  static Stream<List<String>> _syncingStream() =>
      Stream<List<String>>.value(const []);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: BroadcastClient.instance.connectionState,
      builder: (context, online, _) {
        return StreamBuilder<List<String>>(
          stream: _reauthNeededStream(),
          initialData: const [],
          builder: (context, reauthSnap) {
            return StreamBuilder<List<String>>(
              stream: _syncingStream(),
              initialData: const [],
              builder: (context, syncSnap) {
                return _buildTile(
                  context,
                  online: online,
                  reauthNeeded: reauthSnap.data ?? const [],
                  syncing: syncSnap.data ?? const [],
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
    required List<String> reauthNeeded,
    required List<String> syncing,
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

    if (reauthNeeded.isNotEmpty) {
      return ListTile(
        title: 'Reconnect ${reauthNeeded.join(', ')}',
        textStyle: textStyle,
        muted: true,
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
}

/// Internal command that opens the manage-connections modal when the tile is
/// tapped. Optionally renders a custom icon widget so the same tap target can
/// surface a destructive or pulsing icon.
class _OpenManageConnections extends Command {
  _OpenManageConnections({required super.title, this.iconBuilder})
    : super(
        eventObject: EventObject.twist,
        eventAction: EventAction.opened,
      );

  final Widget Function(BuildContext context)? iconBuilder;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) =>
      iconBuilder?.call(context);

  @override
  Future<CommandReturn> run(BuildContext context) =>
      ManageConnections().run(context);
}

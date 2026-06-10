import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/priorities_shell.dart';
import 'package:plot/widget/scaffold.dart';

/// Single-panel "More" tab. Renders the same top-level settings command
/// groups that [ShowSettings] shows as a modal, but as the tab's page body.
///
/// Tapping a row runs the underlying command exactly as the modal does:
/// `ShowCommands`/`ShowForm`/`ShowPage` sub-items open their existing nested
/// modals, and leaf [Command]s run their action (including the destructive
/// [ConfirmModal] flows). Only the top-level list moves from a modal overlay
/// to page content — [ShowSettings] stays intact for desktop / multi-panel.
@RoutePage(name: 'MoreRoute')
class MorePage extends StatefulWidget {
  const MorePage({super.key});

  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  /// Bumped to force [FutureBuilder] to re-run [buildSettingsGroups] after a
  /// command changes settings state (e.g. toggling archived focuses), so the
  /// list reflects the new state — mirroring the modal's refresh.
  int _refreshKey = 0;

  late Future<List<StaticCommandGroup>> _groupsFuture = buildSettingsGroups(
    context,
  );

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _refreshKey++;
      _groupsFuture = buildSettingsGroups(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Tab root: no header (no back affordance — you leave via the bottom bar)
    // and bottom padding for the overlaid nav, matching [PrioritiesPage].
    return Scaffold(
      header: null,
      childPad: false,
      scrollable: false,
      body: SafeArea(
        top: true,
        bottom: false,
        left: false,
        right: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: BottomNavInset.of(context)),
          child: FutureBuilder<List<StaticCommandGroup>>(
            key: ValueKey(_refreshKey),
            future: _groupsFuture,
            builder: (context, snapshot) {
              final groups = snapshot.data ?? const <StaticCommandGroup>[];
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: context.theme.spacing.md),
                    Padding(
                      padding: context.theme.spacing.paddingSm,
                      child: Text(
                        'Settings',
                        style: context.theme.typography.xl.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (final group in groups) ...[
                      if (group.title != null)
                        Padding(
                          padding: context.theme.spacing.paddingSm.copyWith(
                            top: context.theme.spacing.md,
                          ),
                          child: Text(
                            group.title!,
                            style: TextStyle(
                              color: context.theme.colors.mutedForeground,
                              fontSize: context.theme.typography.sm.fontSize,
                            ),
                          ),
                        ),
                      for (final command in group.commands)
                        _SettingsRow(command: command, onRefresh: _refresh),
                    ],
                    SizedBox(height: context.theme.spacing.xl),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// One settings command rendered as a tappable [ListTile]. Routes the result
/// through [Modal.handleCommandResult] so sub-items open their nested modals
/// and a state-changing result refreshes the page list — the same dispatch the
/// command modal uses, minus the modal's own pop (a page has nothing to pop).
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.command, required this.onRefresh});

  final Command command;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      command: command,
      showShortcut: true,
      onRun: (rowContext, result) async {
        await Modal.handleCommandResult(
          rowContext,
          result,
          command,
          rootContext: rowContext,
          onRefresh: () async => onRefresh(),
        );
        // The page is not a modal, so never report "should close".
        return false;
      },
    );
  }
}

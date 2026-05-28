import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/shortcut.dart';
import 'list_tile.dart';
import 'modal.dart';
import 'select_modal.dart';

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({
    required this.label,
    required this.isHighlighted,
    required this.onTap,
  });

  final String label;
  final bool isHighlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isHighlighted
        ? context.theme.colors.foreground
        : context.theme.plotColors.muted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          label.toUpperCase(),
          style: context.theme.typography.sm.copyWith(
            color: color,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

class CommandModal {
  factory CommandModal(
    Commands commands, {
    required BuildContext rootContext,
    bool? showFilter,
    Future<Commands> Function()? commandsBuilder,
  }) {
    return CommandModal._(commands, rootContext, showFilter, commandsBuilder);
  }

  CommandModal._(
    this._commands,
    this.rootContext,
    this.showFilter,
    this.commandsBuilder,
  );

  Commands _commands;
  final BuildContext rootContext;
  final bool? showFilter;
  final Future<Commands> Function()? commandsBuilder;
  Future<void> Function()? _refreshCallback;
  final Map<Command, ListTileController> _controllers = Map.identity();

  /// Invoke a command's [CommandSecondaryAxis.cycle] (badge tap or arrow
  /// key) and route the result through the same refresh pipeline as a
  /// normal command run, so a `CommandRefresh` re-fetches the list and
  /// re-renders the badge with the new label.
  Future<void> _cycleSecondaryAxis(Command command, int delta) async {
    final axis = command.secondaryAxis;
    if (axis == null) return;
    final ctx = rootContext.mounted ? rootContext : null;
    if (ctx == null) return;
    final result = await axis.cycle(ctx, delta);
    if (!ctx.mounted) return;
    await Modal.handleCommandResult(
      ctx,
      result,
      command,
      rootContext: rootContext,
      onRefresh: _refreshCallback,
    );
  }

  Future<CommandReturn> run(BuildContext context) async {
    if (!context.mounted) return CommandSkipped();
    // Clear previous controllers
    _controllers.clear();
    final result = await SelectModal.open<Command>(
      context,
      items: (search) async {
        // Always fetch fresh data to ensure refresh works correctly
        final commandsList = await _commands.list(search: search);
        return commandsList
            .map(
              (cg) => SelectGroup<Command>(
                title: cg.title,
                items: cg.commands,
                infoBuilder: cg.infoBuilder != null
                    ? (context) => cg.infoBuilder!(context, search)
                    : null,
                hint: formatShortcut(cg.shortcut),
                onActivate: cg.onActivate,
              ),
            )
            .toList();
      },
      itemBuilder: (command, _) {
        // Get or create controller for this command (reuse if it exists).
        // Keyed by Command identity so items that share title/subtitle
        // (e.g. two twist instances with the same name) get distinct
        // controllers and Enter targets the highlighted row.
        final controller = _controllers.putIfAbsent(
          command,
          () => ListTileController(),
        );

        // Commands that show modals need modalContext to display UI
        // All other commands get rootContext for provider access
        final wrappedCommand =
            command is ShowCommands ||
                command is ShowForm ||
                command is ShowPage
            ? command
            : CommandWrapper(
                command,
                run: (cmd, ctx) =>
                    cmd.run(rootContext.mounted ? rootContext : ctx),
              );

        final isDisabled = !command.enabled(rootContext);
        final axis = command.secondaryAxis;

        return ListTile(
          controller: controller,
          command: wrappedCommand,
          longPressCommand: command.longPressCommand,
          showShortcut: true,
          onTap: isDisabled ? () {} : null,
          leadingBuilder: command.unread
              ? (isHovered, hasFocus) => SizedBox(
                    width: 20,
                    child: Center(
                      child: Builder(
                        builder: (context) => Container(
                          width: 6.0,
                          height: 6.0,
                          decoration: BoxDecoration(
                            color: context.colour.accent.withValues(alpha: 0.7),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  )
              : null,
          trailingBuilder: axis == null
              ? null
              : (isHovered, hasFocus) => _RoleBadge(
                    label: axis.badgeLabel,
                    isHighlighted: isHovered || hasFocus,
                    onTap: () => _cycleSecondaryAxis(command, 1),
                  ),
          details: command.description != null
              ? Builder(
                  builder: (context) =>
                      command.buildDescription(context) ??
                      Text(
                        command.description!,
                        style: context.theme.typography.sm.copyWith(
                          color: context.theme.plotColors.muted,
                        ),
                      ),
                )
              : null,
          onRun: (context, result) async {
            // Handle the command result using shared Modal handler
            final shouldClose = await Modal.handleCommandResult(
              context,
              result,
              command,
              rootContext: rootContext,
              onRefresh: _refreshCallback,
            );

            // Close modal if handler indicates we should
            if (shouldClose && context.mounted) {
              Modal.pop(context, Value(command));
            }

            return shouldClose;
          },
        );
      },
      prompt: _commands.prompt,
      emptyMessage: _commands.emptyMessage,
      onSelect: (modalContext, command, searchText) async {
        // Get the controller for this command and call run()
        // This ensures spinner state management for Enter key path
        final controller = _controllers[command];

        // Only use controller path if it's attached (ListTile rendered and not disposed)
        if (controller != null && controller.isAttached) {
          await controller.run();
          // Return false because onRun already closed the modal if needed
          return false;
        }

        // Controller doesn't exist or not attached — run command directly without spinner
        final context =
            command is ShowCommands ||
                command is ShowForm ||
                command is ShowPage
            ? modalContext
            : (rootContext.mounted ? rootContext : modalContext);
        if (!context.mounted) return false;
        final result = await command.run(context);

        if (!modalContext.mounted) return false;

        final shouldClose = await Modal.handleCommandResult(
          modalContext,
          result,
          command,
          rootContext: rootContext,
          onRefresh: _refreshCallback,
        );

        if (shouldClose && modalContext.mounted) {
          Modal.pop(modalContext, Value(command));
        }

        return false;
      },
      onRefreshNeeded: (refresh) {
        _refreshCallback = () async {
          if (commandsBuilder != null) {
            _commands = await commandsBuilder!();
            // Rebuilt commands are new instances; drop stale controller refs.
            _controllers.clear();
          }
          await refresh();
        };
      },
      showFilter: showFilter,
      onSecondaryAxis: (command, delta) async {
        await _cycleSecondaryAxis(command, delta);
        return true;
      },
      addTooltip: _commands.secondaryCommand?.call('')?.title,
      onAdd: _commands.secondaryCommand == null
          ? null
          : (modalContext) async {
              final cmd = _commands.secondaryCommand!('');
              if (cmd == null) return null;
              final ctx =
                  cmd is ShowCommands || cmd is ShowForm || cmd is ShowPage
                  ? modalContext
                  : (rootContext.mounted ? rootContext : modalContext);
              if (!ctx.mounted) return null;
              final result = await cmd.run(ctx);
              if (!modalContext.mounted) return null;
              final shouldClose = await Modal.handleCommandResult(
                modalContext,
                result,
                cmd,
                rootContext: rootContext,
                onRefresh: _refreshCallback,
              );
              return shouldClose ? cmd : null;
            },
    );

    return result.present ? const CommandDone() : const CommandSkipped();
  }
}

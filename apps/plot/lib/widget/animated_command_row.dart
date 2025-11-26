import 'package:flutter/widgets.dart';

import 'package:plot/command/command.dart';
import 'button.dart';

/// A widget that animates the reveal/hide of a row of command buttons.
///
/// Used to create consistent slide-to-reveal animations across the app.
class AnimatedCommandRow extends StatelessWidget {
  const AnimatedCommandRow({
    required this.show,
    required this.commands,
    super.key,
  });

  /// Whether to show the commands.
  final bool show;

  /// The list of commands to display as icon buttons.
  final List<Command> commands;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: show && commands.isNotEmpty
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: commands.asMap().entries.map((entry) {
                final key = ValueKey(
                  Object.hash(entry.value.hashCode, entry.key),
                );
                return Button.icon(entry.value, key: key);
              }).toList(),
            )
          : const SizedBox(width: 0, height: 24),
    );
  }
}

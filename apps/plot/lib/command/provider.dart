import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';

import 'base.dart';

typedef RegisterCommandGroups = void Function(List<StaticCommandGroup>? groups);

/// A provider that maintains the current set of command groups
class CommandRegistry extends ChangeNotifier {
  static CommandRegistry of(BuildContext context) {
    final provider =
        context
            .dependOnInheritedWidgetOfExactType<
              CommandRegistryInheritedNotifier
            >()
            ?.notifier;
    assert(provider != null, 'No CommandRegistry found in context');
    return provider!;
  }

  final List<List<StaticCommandGroup>> _commands = [];

  /// Gets all currently available command groups
  List<StaticCommandGroup> get commands =>
      _commands.reversed.flattened.toList();

  /// Pushes a list of command groups to the provider
  RegisterCommandGroups register() {
    final List<StaticCommandGroup> list = [];
    _commands.add(list);
    return (List<StaticCommandGroup>? groups) {
      if (groups == null) {
        _commands.removeWhere((element) => element == list);
        SchedulerBinding.instance.addPostFrameCallback((_) {
          notifyListeners();
        });
        return;
      }
      list.clear();
      list.addAll(groups);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        notifyListeners();
      });
    };
  }
}

/// A Widget that provides CommandRegistry to its child widgets
class CommandProvider extends StatefulWidget {
  final Widget child;

  const CommandProvider({required this.child, super.key});

  @override
  State<CommandProvider> createState() => _CommandProviderState();
}

class _CommandProviderState extends State<CommandProvider> {
  final CommandRegistry _registry = CommandRegistry();

  @override
  void dispose() {
    _registry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CommandRegistryInheritedNotifier(
      notifier: _registry,
      child: widget.child,
    );
  }
}

/// An inherited widget that provides access to CommandRegistry
class CommandRegistryInheritedNotifier
    extends InheritedNotifier<CommandRegistry> {
  const CommandRegistryInheritedNotifier({
    required CommandRegistry notifier,
    required super.child,
    super.key,
  }) : super(notifier: notifier);
}

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';

import 'base.dart';

typedef RegisterActionGroups = void Function(List<StaticActionGroup>? groups);

/// A provider that maintains the current set of action groups
class ActionRegistry extends ChangeNotifier {
  static ActionRegistry of(BuildContext context) {
    final provider = context
        .dependOnInheritedWidgetOfExactType<ActionRegistryInheritedNotifier>()
        ?.notifier;
    assert(provider != null, 'No ActionRegistry found in context');
    return provider!;
  }

  final List<List<StaticActionGroup>> _actions = [];

  /// Gets all currently available action groups
  List<StaticActionGroup> get actions => _actions.reversed.flattened.toList();

  /// Pushes a list of action groups to the provider
  RegisterActionGroups register() {
    final List<StaticActionGroup> list = [];
    _actions.add(list);
    return (List<StaticActionGroup>? groups) {
      if (groups == null) {
        _actions.removeWhere((element) => element == list);
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

/// A Widget that provides ActionRegistry to its child widgets
class ActionProvider extends StatefulWidget {
  final Widget child;

  const ActionProvider({required this.child, super.key});

  @override
  State<ActionProvider> createState() => _ActionProviderState();
}

class _ActionProviderState extends State<ActionProvider> {
  final ActionRegistry _registry = ActionRegistry();

  @override
  void dispose() {
    _registry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ActionRegistryInheritedNotifier(
      notifier: _registry,
      child: widget.child,
    );
  }
}

/// An inherited widget that provides access to ActionRegistry
class ActionRegistryInheritedNotifier
    extends InheritedNotifier<ActionRegistry> {
  const ActionRegistryInheritedNotifier({
    required ActionRegistry notifier,
    required super.child,
    super.key,
  }) : super(notifier: notifier);
}

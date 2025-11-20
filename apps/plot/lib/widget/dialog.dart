import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:drift/drift.dart' show Value;

import 'colour_scheme.dart';

class Dialog extends StatelessWidget {
  const Dialog({
    required this.builder,
    this.header,
    this.constraints = const BoxConstraints(maxHeight: 500, maxWidth: 750),
    this.maxWidthPercentage = 0.8,
    this.maxHeightPercentage = 0.8,
    this.padding = const EdgeInsets.all(16),
    super.key,
  });

  final Widget Function(BuildContext context) builder;
  final Widget? header;
  final BoxConstraints constraints;
  final double maxWidthPercentage;
  final double maxHeightPercentage;
  final EdgeInsets padding;

  Future<Value<T>> show<T>(BuildContext context) {
    return DialogProvider.of(context).push<T>(context, this);
  }

  static void pop<T>(BuildContext context, Value<T> result) {
    DialogProvider.of(context).pop<T>(context, result);
  }

  static void popAll(BuildContext context) {
    DialogProvider.of(context).popAll(context);
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final safeAreaHeight =
        mediaQuery.size.height -
        mediaQuery.viewPadding.top -
        mediaQuery.viewPadding.bottom -
        mediaQuery.viewInsets.bottom;

    BoxConstraints constraints = this.constraints.enforce(
      BoxConstraints(
        maxHeight: safeAreaHeight * maxHeightPercentage,
        maxWidth: mediaQuery.size.width * maxWidthPercentage,
      ),
    );

    return PlatformBuilder(
      builder: (_) => FDialog.raw(
        // ignore: unused_result
        style: context.theme.dialogStyle.copyWith(
          decoration: BoxDecoration(
            color: context.colour.modalBackground,
            border: Border.all(color: context.colour.border),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        builder: (context, style) => Padding(
          padding: EdgeInsets.all(1),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (header != null) header!,
                Container(
                  padding: padding,
                  child: ConstrainedBox(
                    constraints: constraints,
                    child: builder(context),
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

class DialogProvider extends StatefulWidget {
  const DialogProvider({required this.child, super.key});

  final Widget child;

  @override
  State<DialogProvider> createState() => _DialogProviderState();

  // ignore: library_private_types_in_public_api
  static _DialogProviderInherited of(BuildContext context) {
    final _DialogProviderInherited? provider =
        context
            .dependOnInheritedWidgetOfExactType<_InnerDialogProvider>()
            ?.provider ??
        context.dependOnInheritedWidgetOfExactType<_DialogProviderInherited>();
    assert(provider != null, 'No DialogProvider found in context');
    return provider!;
  }
}

class _DialogProviderState extends State<DialogProvider> {
  final List<_DialogStackItem<dynamic>> _dialogStack = [];
  final ValueNotifier<int> _dialogStackNotifier = ValueNotifier<int>(0);
  final GlobalKey _rootContextKey = GlobalKey();

  Future<Value<T>> push<T>(BuildContext context, Widget dialog) async {
    final stackItem = _DialogStackItem<T>(dialog);

    _dialogStack.add(stackItem);
    _notifyStackChanged();

    if (_dialogStack.length == 1) {
      // Use root context if available, otherwise fall back to passed context
      final dialogContext = _rootContextKey.currentContext ?? context;

      final result = await showFDialog<Value<T>>(
        context: dialogContext,
        builder: (context, _, _) {
          final provider = _DialogProviderInherited._(
            dialogStack: _dialogStack,
            dialogStackNotifier: _dialogStackNotifier,
            state: this,
            child: _DialogStackDisplay(
              dialogStack: _dialogStack,
              dialogStackNotifier: _dialogStackNotifier,
            ),
          );
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () {
                pop(context, Value<T>.absent());
              },
            },
            child: _InnerDialogProvider(provider, child: provider),
          );
        },
      );
      _dialogStack.clear();
      return result ?? Value.absent();
    } else {
      return stackItem.completer.future;
    }
  }

  void pop<T>(BuildContext context, Value<T> result) {
    if (_dialogStack.isNotEmpty) {
      final stackItem = _dialogStack.removeLast();
      stackItem.completer.complete(result);
    }

    if (_dialogStack.isEmpty) {
      Navigator.of(context).maybePop(result);
    } else {
      _notifyStackChanged();
    }
  }

  void popAll(BuildContext context) {
    while (_dialogStack.isNotEmpty) {
      final stackItem = _dialogStack.removeLast();
      stackItem.completeAbsent();
    }
    Navigator.of(context).maybePop();
  }

  void _notifyStackChanged() {
    _dialogStackNotifier.value = _dialogStack.length;
  }

  @override
  Widget build(BuildContext context) {
    return _DialogProviderInherited._(
      dialogStack: _dialogStack,
      dialogStackNotifier: _dialogStackNotifier,
      state: this,
      child: Container(key: _rootContextKey, child: widget.child),
    );
  }

  @override
  void dispose() {
    _dialogStackNotifier.dispose();
    super.dispose();
  }
}

class _DialogProviderInherited extends InheritedWidget {
  const _DialogProviderInherited._({
    required this.dialogStack,
    required this.dialogStackNotifier,
    required this.state,
    required super.child,
  });

  final List<_DialogStackItem<dynamic>> dialogStack;
  final ValueNotifier<int> dialogStackNotifier;
  final _DialogProviderState state;

  Future<Value<T>> push<T>(BuildContext context, Widget dialog) {
    return state.push<T>(context, dialog);
  }

  void pop<T>(BuildContext context, Value<T> result) {
    state.pop<T>(context, result);
  }

  void popAll(BuildContext context) {
    state.popAll(context);
  }

  @override
  bool updateShouldNotify(_DialogProviderInherited oldWidget) => false;
}

class _DialogStackItem<T> {
  _DialogStackItem(this.dialog);

  final Widget dialog;
  final Completer<Value<T>> completer = Completer<Value<T>>();

  void completeAbsent() => completer.complete(Value.absent());
}

class _DialogStackDisplay extends StatefulWidget {
  const _DialogStackDisplay({
    required this.dialogStack,
    required this.dialogStackNotifier,
  });

  final List<_DialogStackItem<dynamic>> dialogStack;
  final ValueNotifier<int> dialogStackNotifier;

  @override
  State<_DialogStackDisplay> createState() => _DialogStackDisplayState();
}

class _DialogStackDisplayState extends State<_DialogStackDisplay> {
  @override
  void initState() {
    super.initState();
    widget.dialogStackNotifier.addListener(_onStackChanged);
  }

  @override
  void dispose() {
    widget.dialogStackNotifier.removeListener(_onStackChanged);
    super.dispose();
  }

  void _onStackChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (widget.dialogStack.isEmpty) {
      return const SizedBox.shrink();
    }
    return widget.dialogStack.last.dialog;
  }
}

class _InnerDialogProvider extends InheritedWidget {
  const _InnerDialogProvider(this.provider, {required super.child});

  final _DialogProviderInherited provider;

  @override
  bool updateShouldNotify(_InnerDialogProvider oldWidget) =>
      child != oldWidget.child;
}

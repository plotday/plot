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

class DialogProvider extends InheritedWidget {
  DialogProvider({required super.child, super.key})
    : _dialogStack = <_DialogStackItem<dynamic>>[];

  final List<_DialogStackItem<dynamic>> _dialogStack;

  Future<Value<T>> push<T>(BuildContext context, Widget dialog) async {
    final stackItem = _DialogStackItem<T>(dialog);

    _dialogStack.add(stackItem);
    _notifyStackChanged();

    if (_dialogStack.length == 1) {
      final result = await showFDialog<Value<T>>(
        context: context,
        builder: (context, _, _) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              pop(context, Value<T>.absent());
            },
          },
          child: _InnerDialogProvider(
            this,
            child: _DialogStackDisplay(provider: this),
          ),
        ),
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

  final ValueNotifier<int> _dialogStackNotifier = ValueNotifier<int>(0);

  static DialogProvider of(BuildContext context) {
    final DialogProvider? provider =
        context
            .dependOnInheritedWidgetOfExactType<_InnerDialogProvider>()
            ?.provider ??
        context.dependOnInheritedWidgetOfExactType<DialogProvider>();
    assert(provider != null, 'No DialogProvider found in context');
    return provider!;
  }

  @override
  bool updateShouldNotify(DialogProvider oldWidget) => false;
}

class _DialogStackItem<T> {
  _DialogStackItem(this.dialog);

  final Widget dialog;
  final Completer<Value<T>> completer = Completer<Value<T>>();

  void completeAbsent() => completer.complete(Value.absent());
}

class _DialogStackDisplay extends StatefulWidget {
  const _DialogStackDisplay({required this.provider});

  final DialogProvider provider;

  @override
  State<_DialogStackDisplay> createState() => _DialogStackDisplayState();
}

class _DialogStackDisplayState extends State<_DialogStackDisplay> {
  @override
  void initState() {
    super.initState();
    widget.provider._dialogStackNotifier.addListener(_onStackChanged);
  }

  @override
  void dispose() {
    widget.provider._dialogStackNotifier.removeListener(_onStackChanged);
    super.dispose();
  }

  void _onStackChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (widget.provider._dialogStack.isEmpty) {
      return const SizedBox.shrink();
    }
    return widget.provider._dialogStack.last.dialog;
  }
}

class _InnerDialogProvider extends InheritedWidget {
  const _InnerDialogProvider(this.provider, {required super.child});

  final DialogProvider provider;

  @override
  bool updateShouldNotify(_InnerDialogProvider oldWidget) =>
      child != oldWidget.child;
}

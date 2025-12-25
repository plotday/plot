import 'dart:async';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:forui/forui.dart';
import 'package:drift/drift.dart' show Value;
import 'package:plot/state/layout.dart';
import 'package:plot/widget/logging.dart';

class Modal extends StatelessWidget {
  const Modal({
    required this.builder,
    this.header,
    this.constraints = const BoxConstraints(maxHeight: 640, maxWidth: 750),
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
    return ModalProvider.of(context).push<T>(context, this);
  }

  static void pop<T>(BuildContext context, Value<T> result) {
    ModalProvider.of(context).pop<T>(context, result);
  }

  static Future<void> popAll(BuildContext context) {
    return ModalProvider.of(context).popAll(context);
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
        maxWidth: max(
          mediaQuery.size.width * maxWidthPercentage,
          min(mediaQuery.size.width, this.constraints.maxWidth),
        ),
      ),
    );

    // Return the content directly - the push() method already handles
    // wrapping in FDialog or FSheet based on multiPanel
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (header != null) header!,
        Flexible(
          child: Container(
            padding: padding,
            child: ConstrainedBox(
              constraints: constraints,
              child: builder(context),
            ),
          ),
        ),
      ],
    );
  }
}

class ModalProvider extends StatefulWidget {
  const ModalProvider({required this.child, super.key});

  final Widget child;

  @override
  State<ModalProvider> createState() => _ModalProviderState();

  // ignore: library_private_types_in_public_api
  static _ModalProviderInherited of(BuildContext context) {
    final _ModalProviderInherited? provider =
        context
            .dependOnInheritedWidgetOfExactType<_InnerModalProvider>()
            ?.provider ??
        context.dependOnInheritedWidgetOfExactType<_ModalProviderInherited>();
    assert(provider != null, 'No ModalProvider found in context');
    return provider!;
  }
}

class _ModalProviderState extends State<ModalProvider> {
  final List<_ModalStackItem<dynamic>> _modalStack = [];
  final ValueNotifier<int> _modalStackNotifier = ValueNotifier<int>(0);
  final GlobalKey _rootContextKey = GlobalKey();

  Future<Value<T>> push<T>(BuildContext context, Widget modal) async {
    final stackItem = _ModalStackItem<T>(modal);

    _modalStack.add(stackItem);
    _notifyStackChanged();
    if (_modalStack.length == 1) {
      // Use root context if available, otherwise fall back to passed context
      final modalContext = _rootContextKey.currentContext ?? context;
      final multiPanel = context.isMultiPanel;

      final provider = _ModalProviderInherited._(
        modalStack: _modalStack,
        modalStackNotifier: _modalStackNotifier,
        state: this,
        child: _ModalStackDisplay(
          modalStack: _modalStack,
          modalStackNotifier: _modalStackNotifier,
        ),
      );

      Widget buildModalContent(BuildContext dialogContext) {
        return Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (intent) {
                dismiss(dialogContext, Value<T>.absent());
                return null;
              },
            ),
          },
          child: Focus(
            autofocus: true,
            child: _InnerModalProvider(provider, child: provider),
          ),
        );
      }

      final Value<T> result;
      if (multiPanel) {
        // Calculate dialog positioning for desktop/tablet
        final mediaQuery = MediaQuery.of(modalContext);
        final screenHeight = mediaQuery.size.height;

        // Get dialog height from constraints
        double dialogHeight = 640; // default max height
        if (stackItem.modal is Modal) {
          final modalWidget = stackItem.modal as Modal;
          final safeAreaHeight =
              screenHeight -
              mediaQuery.viewPadding.top -
              mediaQuery.viewPadding.bottom -
              mediaQuery.viewInsets.bottom;

          final constraints = modalWidget.constraints.enforce(
            BoxConstraints(
              maxHeight: safeAreaHeight * modalWidget.maxHeightPercentage,
              maxWidth: max(
                mediaQuery.size.width * modalWidget.maxWidthPercentage,
                min(mediaQuery.size.width, modalWidget.constraints.maxWidth),
              ),
            ),
          );
          dialogHeight = constraints.maxHeight;
        }

        // Position between 10% and 25% from top, preferring 25% but never below center
        final centeredY = (screenHeight - dialogHeight) / 2;
        final preferredY = screenHeight * 0.25;
        final anchorY = min(preferredY, centeredY);

        // Desktop/tablet: Use FDialog with custom styling
        result =
            await showFDialog<Value<T>>(
              context: modalContext,
              builder: (dialogContext, _, _) => Column(
                children: [
                  SizedBox(height: anchorY),
                  FDialog.raw(
                    // ignore: unused_result
                    style: dialogContext.theme.dialogStyle.copyWith(
                      decoration: BoxDecoration(
                        color: dialogContext.theme.colors.background,
                        border: Border.all(
                          color: dialogContext.theme.colors.border,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    builder: (context, style) => Padding(
                      padding: EdgeInsets.all(1),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: buildModalContent(dialogContext),
                      ),
                    ),
                  ),
                ],
              ),
            ) ??
            Value.absent();
      } else {
        // Mobile: Use FSheet
        result =
            await showFSheet<Value<T>>(
              context: context,
              side: FLayout.btt,
              useRootNavigator: true,
              barrierDismissible: true,
              draggable: true,
              useSafeArea: true,
              mainAxisMaxRatio: 1,
              builder: (dialogContext) {
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(modalContext).viewInsets.bottom,
                  ),
                  child: material.Material(
                    child: Container(
                      color: dialogContext.theme.colors.background,
                      child: buildModalContent(dialogContext),
                    ),
                  ),
                );
              },
            ) ??
            Value.absent();
      }

      _modalStack.clear();
      return result;
    } else {
      return stackItem.completer.future;
    }
  }

  void pop<T>(BuildContext context, Value<T> result) {
    if (_modalStack.isEmpty) return;

    final stackItem = _modalStack.removeLast();
    // Check if this is the last modal BEFORE completing the completer,
    // because completing may trigger a cascade of pops that empties the stack
    final shouldCloseDialog = _modalStack.isEmpty;

    // Complete the completer - this may synchronously trigger more pops
    stackItem.completer.complete(result);

    // Only close dialog if WE are the one that emptied the stack,
    // not if a cascaded pop already closed it
    if (shouldCloseDialog) {
      final modalContext = _rootContextKey.currentContext ?? context;
      final navigator = Navigator.of(modalContext);
      if (navigator.canPop()) {
        navigator.pop(result);
      } else {
        log.warning('Cannot pop - navigator says canPop is false');
      }
    } else if (_modalStack.isNotEmpty) {
      _notifyStackChanged();
    }
  }

  void dismiss(BuildContext context, Value<dynamic> value) {
    if (_modalStack.isEmpty) return;

    final stackItem = _modalStack.removeLast();
    // Check if this is the last modal BEFORE completing the completer,
    // because completing may trigger a cascade of pops that empties the stack
    final shouldCloseDialog = _modalStack.isEmpty;

    // Complete with absent value - this may synchronously trigger more pops
    stackItem.completeAbsent();

    // Only close dialog if WE are the one that emptied the stack,
    // not if a cascaded pop already closed it
    if (shouldCloseDialog) {
      final modalContext = _rootContextKey.currentContext ?? context;
      final navigator = Navigator.of(modalContext);
      if (navigator.canPop()) {
        navigator.pop(value);
      } else {
        log.warning('Cannot pop - navigator says canPop is false');
      }
    } else if (_modalStack.isNotEmpty) {
      _notifyStackChanged();
    }
  }

  Future<void> popAll(BuildContext context) async {
    while (_modalStack.isNotEmpty) {
      final stackItem = _modalStack.removeLast();
      stackItem.completeAbsent();
    }
    // Use the same context that was used to create the dialog
    final modalContext = _rootContextKey.currentContext ?? context;
    await Navigator.of(modalContext).maybePop();
  }

  void _notifyStackChanged() {
    _modalStackNotifier.value = _modalStack.length;
  }

  @override
  Widget build(BuildContext context) {
    return _ModalProviderInherited._(
      modalStack: _modalStack,
      modalStackNotifier: _modalStackNotifier,
      state: this,
      child: Container(key: _rootContextKey, child: widget.child),
    );
  }

  @override
  void dispose() {
    _modalStackNotifier.dispose();
    super.dispose();
  }
}

class _ModalProviderInherited extends InheritedWidget {
  const _ModalProviderInherited._({
    required this.modalStack,
    required this.modalStackNotifier,
    required this.state,
    required super.child,
  });

  final List<_ModalStackItem<dynamic>> modalStack;
  final ValueNotifier<int> modalStackNotifier;
  final _ModalProviderState state;

  Future<Value<T>> push<T>(BuildContext context, Widget modal) {
    return state.push<T>(context, modal);
  }

  void pop<T>(BuildContext context, Value<T> result) {
    state.pop<T>(context, result);
  }

  void dismiss(BuildContext context, Value<dynamic> value) {
    state.dismiss(context, value);
  }

  Future<void> popAll(BuildContext context) {
    return state.popAll(context);
  }

  @override
  bool updateShouldNotify(_ModalProviderInherited oldWidget) => false;
}

class _ModalStackItem<T> {
  _ModalStackItem(this.modal);

  final Widget modal;
  final Completer<Value<T>> completer = Completer<Value<T>>();

  void completeAbsent() => completer.complete(Value.absent());
}

class _ModalStackDisplay extends StatefulWidget {
  const _ModalStackDisplay({
    required this.modalStack,
    required this.modalStackNotifier,
  });

  final List<_ModalStackItem<dynamic>> modalStack;
  final ValueNotifier<int> modalStackNotifier;

  @override
  State<_ModalStackDisplay> createState() => _ModalStackDisplayState();
}

class _ModalStackDisplayState extends State<_ModalStackDisplay> {
  @override
  void initState() {
    super.initState();
    widget.modalStackNotifier.addListener(_onStackChanged);
  }

  @override
  void dispose() {
    widget.modalStackNotifier.removeListener(_onStackChanged);
    super.dispose();
  }

  void _onStackChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (widget.modalStack.isEmpty) {
      return const SizedBox.shrink();
    }
    // Use IndexedStack to keep all modal states alive while only showing the top one.
    // This prevents state loss when modals are pushed on top and then popped.
    // Use loose sizing so the stack sizes to the current visible child.
    return IndexedStack(
      index: widget.modalStack.length - 1,
      sizing: StackFit.loose,
      children: widget.modalStack.map((item) => item.modal).toList(),
    );
  }
}

class _InnerModalProvider extends InheritedWidget {
  const _InnerModalProvider(this.provider, {required super.child});

  final _ModalProviderInherited provider;

  @override
  bool updateShouldNotify(_InnerModalProvider oldWidget) =>
      child != oldWidget.child;
}

import 'dart:async';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:forui/forui.dart';
import 'package:plot/command/command.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/widget/logging.dart';
import 'package:plot/widget/toast.dart';

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

  /// Handle command result in modal context
  /// Returns true if modal should be closed
  static Future<bool> handleCommandResult(
    BuildContext modalContext,
    CommandReturn result,
    Command command, {
    required BuildContext rootContext,
    Future<void> Function()? onRefresh,
  }) async {
    if (!modalContext.mounted) return false;

    // Keep modal open if command was skipped or returned error
    if (result is CommandSkipped) {
      return false;
    }

    if (result is CommandMessage && result.isError) {
      modalContext.showToast(
        title: result.title,
        message: result.message,
        isError: true,
      );
      return false;
    }

    // Handle CommandRefresh - show message, refresh, keep modal open
    if (result is CommandRefresh) {
      if (result.message != null && modalContext.mounted) {
        modalContext.showOverlayToast(
          title: result.title,
          message: result.message!,
        );
      }
      if (onRefresh != null) {
        await onRefresh();
      }
      return false;
    }

    // Show success message if provided
    if (result is CommandMessage && !result.isError) {
      if (modalContext.mounted) {
        modalContext.showOverlayToast(
          title: result.title,
          message: result.message,
        );
      }
    }

    // Handle CommandRoute - close all modals and navigate
    if (result is CommandRoute) {
      Modal.popAll(modalContext);
      if (modalContext.mounted) {
        final routeContext = rootContext.mounted ? rootContext : modalContext;
        await result.go(routeContext);
      }
      return false; // Already closed
    }

    // Check if command opens its own modal - keep parent modal open
    if (command is ShowCommands || command is ShowForm || command is ShowPage) {
      if (result is! CommandSkipped && onRefresh != null) {
        await onRefresh();
      }
      return false;
    }

    // Close modal for successful commands
    return true;
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
    return LayoutBuilder(
      builder: (context, parentConstraints) {
        // Constrain to the minimum of parent constraints and our max constraints
        final effectiveConstraints = BoxConstraints(
          maxWidth: constraints.maxWidth,
          maxHeight: parentConstraints.maxHeight.isFinite
              ? parentConstraints.maxHeight
              : constraints.maxHeight,
        );

        return ConstrainedBox(
          constraints: effectiveConstraints,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (header != null) header!,
              Flexible(
                child: Container(padding: padding, child: builder(context)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ModalProvider extends StatefulWidget {
  const ModalProvider({required this.child, super.key});

  final Widget child;

  /// Whether any ModalProvider currently has open modals.
  static bool get hasOpenModals => _ModalProviderState.hasOpenModals;

  /// Dismisses the top modal of the first provider with open modals.
  /// Returns true if a modal was dismissed.
  static bool tryDismissTopModal(BuildContext context) =>
      _ModalProviderState.tryDismissTopModal(context);

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
  static final Set<_ModalProviderState> _activeProviders = {};

  /// Whether any ModalProvider currently has open modals.
  static bool get hasOpenModals =>
      _activeProviders.any((p) => p._modalStack.isNotEmpty);

  /// Dismisses the top modal of the first provider with open modals.
  /// Returns true if a modal was dismissed.
  static bool tryDismissTopModal(BuildContext context) {
    for (final provider in _activeProviders) {
      if (provider._modalStack.isNotEmpty) {
        final modalContext = provider._rootContextKey.currentContext ?? context;
        provider.dismiss(modalContext, Value<dynamic>.absent());
        return true;
      }
    }
    return false;
  }

  final List<_ModalStackItem<dynamic>> _modalStack = [];
  final ValueNotifier<int> _modalStackNotifier = ValueNotifier<int>(0);
  final GlobalKey _rootContextKey = GlobalKey();
  bool _usedRootNavigator = false;

  @override
  void initState() {
    super.initState();
    _activeProviders.add(this);
  }

  Future<Value<T>> push<T>(BuildContext context, Widget modal) async {
    final stackItem = _ModalStackItem<T>(modal);

    _modalStack.add(stackItem);
    _notifyStackChanged();
    if (_modalStack.length == 1) {
      // Use root context if available, otherwise fall back to passed context
      final modalContext = _rootContextKey.currentContext ?? context;
      final multiPanel = context.isMultiPanel;
      _usedRootNavigator = !multiPanel;

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
        return ValueListenableBuilder<int>(
          valueListenable: _modalStackNotifier,
          builder: (context, stackLength, child) => PopScope(
            canPop: stackLength <= 1,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) {
                dismiss(dialogContext, Value<T>.absent());
              }
            },
            child: child!,
          ),
          child: Actions(
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
          ),
        );
      }

      final Value<T> result;
      if (multiPanel) {
        // Desktop/tablet: Use FDialog with custom styling
        result =
            await showFDialog<Value<T>>(
              context: modalContext,
              builder: (dialogContext, _, _) => FToaster(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Position at 15% from top with max height of 80%
                    final screenHeight = constraints.maxHeight;
                    final maxDialogHeight = screenHeight * 0.8;
                    return FDialog.raw(
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
                      constraints: BoxConstraints(
                        maxHeight: maxDialogHeight,
                        maxWidth: 560,
                      ),
                      builder: (context, style) => Padding(
                        padding: EdgeInsets.all(1),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: buildModalContent(dialogContext),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ) ??
            Value.absent();
      } else {
        // Mobile: Use FSheet
        result =
            await showFSheet<Value<T>>(
              context: modalContext,
              side: FLayout.btt,
              useRootNavigator: true,
              barrierDismissible: true,
              draggable: true,
              useSafeArea: true,
              mainAxisMaxRatio: 1,
              builder: (dialogContext) {
                return FToaster(
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
    // For absent values, use completeAbsent() to avoid type mismatches
    if (!result.present) {
      stackItem.completeAbsent();
    } else {
      // For present values, we need to handle potential type mismatches when
      // nested modals have different type parameters. This can happen when
      // a SelectModal<Command> is opened from within a FormModal<CommandReturn>.
      // We use dynamic casting as a workaround.
      // ignore: argument_type_not_assignable
      stackItem.completer.complete(result as dynamic);
    }

    // Only close dialog if WE are the one that emptied the stack,
    // not if a cascaded pop already closed it
    if (shouldCloseDialog) {
      final modalContext = _rootContextKey.currentContext ?? context;
      final navigator = Navigator.of(
        modalContext,
        rootNavigator: _usedRootNavigator,
      );
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
      final navigator = Navigator.of(
        modalContext,
        rootNavigator: _usedRootNavigator,
      );
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
    await Navigator.of(
      modalContext,
      rootNavigator: _usedRootNavigator,
    ).maybePop();
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
    _activeProviders.remove(this);
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
    // Show only the top modal, but keep all modals in the tree using Offstage
    // to preserve their state. This allows the dialog to resize to fit the visible modal.
    return Stack(
      fit: StackFit.loose,
      children: [
        for (int i = 0; i < widget.modalStack.length; i++)
          Offstage(
            offstage: i != widget.modalStack.length - 1,
            child: widget.modalStack[i].modal,
          ),
      ],
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

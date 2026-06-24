import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:forui/forui.dart';
import 'package:plot/command/command.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/logging.dart';
import 'package:plot/widget/toast.dart';

/// Reserved space (px) on the top-right of modals to keep clear of the
/// floating close button. Input-at-top modals add this as right-padding to
/// their top row so the X doesn't visually collide with their content.
const double modalCloseButtonReservedWidth = 40;

/// Reserved vertical space (px) at the top of a modal whose content has no
/// header row to absorb the floating close button (e.g. a header-less select
/// list shown as a mobile bottom sheet). Reserve this as top space so the X
/// doesn't overlap the first row.
const double modalCloseButtonReservedHeight = 40;

class Modal extends StatelessWidget {
  const Modal({
    required this.builder,
    this.header,
    this.constraints = const BoxConstraints(maxHeight: 640, maxWidth: 750),
    this.maxWidthPercentage = 0.8,
    this.maxHeightPercentage = 0.8,
    this.padding = const EdgeInsets.all(16),
    this.showCloseButton = true,
    super.key,
  });

  final Widget Function(BuildContext context) builder;
  final Widget? header;
  final BoxConstraints constraints;
  final double maxWidthPercentage;
  final double maxHeightPercentage;
  final EdgeInsets padding;

  /// Whether this modal should show the floating close (X) button in the
  /// top-right corner when it is the top of the modal stack. Shown on both
  /// dialogs (multi-panel) and bottom sheets (single-panel) so every
  /// top-level modal has an explicit close affordance. Nested modals never
  /// show it — they render their own back button instead.
  final bool showCloseButton;

  Future<Value<T>> show<T>(BuildContext context) {
    return ModalProvider.of(context).push<T>(context, this);
  }

  static void pop<T>(BuildContext context, Value<T> result) {
    ModalProvider.of(context).pop<T>(context, result);
  }

  /// Pops the top modal but keeps it on display until the next [Modal.show]
  /// (push) replaces it, swapping the two in a single frame. Use to hand off
  /// from one modal to another (e.g. the connection auth screen to its
  /// channel-setup screen after OAuth) without the modal beneath — typically
  /// the connections list — flashing into view during the gap while the next
  /// modal loads its data.
  ///
  /// The caller MUST follow this with a push (open the next modal). Until then
  /// the handed-off modal stays on screen; a user dismiss (Esc/X) still removes
  /// it normally.
  static void popForSwap<T>(BuildContext context, Value<T> result) {
    ModalProvider.of(context).popForSwap<T>(context, result);
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
      modalContext.showOverlayToast(
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
        // Fire-and-forget: the mutation already committed optimistically to
        // local Drift, so the calling row's spinner shouldn't be pinned on
        // the picker's re-fetch of contacts/actors.
        unawaited(onRefresh());
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

    // ShowCommands: propagate CommandDone to close parent modal stack
    if (command is ShowCommands) {
      if (result is CommandDone) {
        return true; // Child completed — close parent too
      }
      if (result is! CommandSkipped && onRefresh != null) {
        await onRefresh();
      }
      return false;
    }

    // ShowForm/ShowPage: always keep parent modal open
    if (command is ShowForm || command is ShowPage) {
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

        final content = ConstrainedBox(
          constraints: effectiveConstraints,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?header,
              Flexible(
                child: Container(padding: padding, child: builder(context)),
              ),
            ],
          ),
        );

        final Widget? closeButton = showCloseButton
            ? const Positioned(top: 8, right: 8, child: _ModalCloseButton())
            : null;

        // In single-panel mode the modal is presented as a full-width bottom
        // sheet. Stretch horizontally (Row.mainAxisSize.max) so the content is
        // centred within the sheet while the close (X) button anchors to the
        // top-right of the whole panel rather than the (narrower) content.
        // Using a Row keeps the vertical axis shrink-wrapped to the content so
        // the sheet still sizes to its content height. Multi-panel dialogs
        // instead size to the content, so the X sits at the content's corner.
        if (!context.isMultiPanel) {
          return Stack(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [Flexible(child: content)],
              ),
              ?closeButton,
            ],
          );
        }

        return Stack(children: [content, ?closeButton]);
      },
    );
  }
}

/// Floating close (X) button rendered by [Modal] in the top-right corner.
/// Visible when the modal is the top of the stack, on both dialogs
/// (multi-panel) and bottom sheets (single-panel) — every top-level modal
/// gets an explicit close affordance, in addition to swipe-to-dismiss on
/// sheets. Nested modals show their own back button instead.
///
/// Hovering brightens the X from [mutedForeground] to [foreground] and shows
/// a "Close" tooltip with the "Esc" shortcut below (on devices with a physical
/// keyboard, where Esc dismisses the modal).
class _ModalCloseButton extends StatefulWidget {
  const _ModalCloseButton();

  @override
  State<_ModalCloseButton> createState() => _ModalCloseButtonState();
}

class _ModalCloseButtonState extends State<_ModalCloseButton> {
  static const _shortcut = SingleActivator(LogicalKeyboardKey.escape);

  bool _isHovered = false;

  Widget _buildTooltip(BuildContext context) {
    if (!hasPhysicalKeyboard()) return const Text('Close');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Close'),
        Text(
          formatShortcut(_shortcut),
          style: context.theme.typography.xs.copyWith(
            color: context.theme.colors.mutedForeground,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ModalProvider.of(context).modalStackNotifier,
      builder: (context, stackLength, _) {
        if (stackLength > 1) return const SizedBox.shrink();
        return FTooltip(
          tipBuilder: (context, _) => _buildTooltip(context),
          child: MouseRegion(
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            child: FButton.icon(
              variant: FButtonVariant.ghost,
              onPress: () =>
                  Modal.pop<dynamic>(context, Value<dynamic>.absent()),
              child: Icon(
                PlotIcon.close,
                size: context.theme.iconSizes.sm,
                color: _isHovered
                    ? context.theme.colors.foreground
                    : context.theme.colors.mutedForeground,
              ),
            ),
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

  /// Reactive view of [hasOpenModals]. Lets widgets outside the provider
  /// tree (e.g. the [Window] frame) react when any modal opens or closes.
  static ValueListenable<bool> get hasOpenModalsListenable =>
      _ModalProviderState._hasOpenModalsNotifier;

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
    if (provider != null) return provider;
    // No ModalProvider in this context's ancestry — e.g. a focus deep in an
    // overlay/route mounted above the shell. Fall back to the outermost
    // provider so top-level modals (the ⌘/Ctrl-K command palette, pickers,
    // confirms) open from anywhere instead of asserting. Only fails if no
    // ModalProvider is mounted at all (shouldn't happen after startup).
    final _ModalProviderInherited? root = _ModalProviderState._root?._inherited;
    assert(root != null, 'No ModalProvider found in context or globally');
    return root!;
  }
}

class _ModalProviderState extends State<ModalProvider> {
  static final Set<_ModalProviderState> _activeProviders = {};

  /// The outermost (root) provider — the global fallback [ModalProvider.of]
  /// uses when a caller's context has no ModalProvider ancestor.
  static _ModalProviderState? _root;

  /// This provider's current inherited widget (rebuilt each [build]); returned
  /// by [ModalProvider.of]'s root fallback.
  _ModalProviderInherited? _inherited;

  /// Cross-provider notifier for [ModalProvider.hasOpenModalsListenable].
  /// Updated by [_notifyStackChanged] whenever any provider's stack toggles
  /// between empty and non-empty.
  static final ValueNotifier<bool> _hasOpenModalsNotifier = ValueNotifier(
    false,
  );

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

  /// A modal popped via [popForSwap] that is kept on display (still the visible
  /// top) until the next [push] swaps it out atomically. See [popForSwap].
  _ModalStackItem<dynamic>? _retainedForSwap;

  @override
  void initState() {
    super.initState();
    _activeProviders.add(this);
  }

  Future<Value<T>> push<T>(BuildContext context, Widget modal) {
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

      // Extract constraints from Modal widget if available.
      // Default dialog max is 560; modals with custom maxWidthPercentage
      // (e.g. image viewer at 0.9) pass through their own constraints.
      final hasCustomWidth =
          modal is Modal && modal.maxWidthPercentage != 0.8;
      final modalMaxWidth = modal is Modal && hasCustomWidth
          ? modal.constraints.maxWidth
          : 560.0;
      final modalMaxHeight = modal is Modal
          ? modal.constraints.maxHeight
          : 640.0;

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

      // Results flow through stackItem.completer. showFDialog/showFSheet are
      // fire-and-forget: we can't pass a typed result through navigator.pop
      // because nested modals may have a different T than the first modal.
      final Future<dynamic> dialogFuture;
      if (multiPanel) {
        // Desktop/tablet: Use FDialog with custom styling
        dialogFuture = showFDialog<dynamic>(
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
                    decoration: DecorationDelta.value(BoxDecoration(
                      color: dialogContext.theme.colors.background,
                      border: Border.all(
                        color: dialogContext.theme.colors.border,
                      ),
                      borderRadius: BorderRadius.circular(borderRadiusMd),
                    )),
                  ),
                  constraints: BoxConstraints(
                    maxHeight: min(maxDialogHeight, modalMaxHeight),
                    maxWidth: modalMaxWidth,
                  ),
                  builder: (context, style) => Padding(
                    padding: EdgeInsets.all(1),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(borderRadiusMd),
                      child: buildModalContent(dialogContext),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      } else {
        // Mobile: Use FSheet
        dialogFuture = showFSheet<dynamic>(
          context: modalContext,
          side: FLayout.btt,
          useRootNavigator: true,
          barrierDismissible: true,
          draggable: true,
          useSafeArea: true,
          mainAxisMaxRatio: 1,
          builder: (dialogContext) {
            // Don't wrap in FToaster: forui 0.21+ FToaster wraps with
            // Overlay.wrap, which forces its child to fill the available
            // constraints — that breaks the sheet's shrink-wrap to content.
            // The app-level FToaster in app.dart is still an ancestor of
            // root-navigator routes, so showFToast calls keep working.
            // The modal content stretches edge-to-edge in single-panel mode
            // (see Modal.build), so the sheet background and its top border
            // span the full width. A 1px top border separates the sheet from
            // the dimmed feed behind it.
            return material.Material(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: dialogContext.theme.colors.background,
                  border: Border(
                    top: BorderSide(color: dialogContext.theme.colors.border),
                  ),
                ),
                child: buildModalContent(dialogContext),
              ),
            );
          },
        );
      }

      // When the dialog closes for any reason (including barrier dismiss),
      // drain the stack so any unresolved completers complete with absent.
      unawaited(dialogFuture.whenComplete(() {
        _retainedForSwap = null;
        while (_modalStack.isNotEmpty) {
          _modalStack.removeLast().completeAbsent();
        }
        _notifyStackChanged();
      }));
    }

    // A modal handed off via [popForSwap] stayed on display (covering the modal
    // beneath it) while this new modal loaded. Now that the new modal is on the
    // stack as the top, drop the retained one: it sits directly beneath the new
    // top, so removing it is invisible — and the modal beneath THAT (e.g. the
    // connections list) never flashes into view during the hand-off. Done after
    // the length==1 dialog-open check so the retained item, which kept the
    // stack non-empty, doesn't make this push reopen the dialog route.
    final retained = _retainedForSwap;
    if (retained != null) {
      _retainedForSwap = null;
      _modalStack.remove(retained);
      _notifyStackChanged();
    }
    return stackItem.completer.future;
  }

  /// Pops the top modal but KEEPS it on the stack and on display until the next
  /// [push] replaces it. See [Modal.popForSwap] for the rationale.
  void popForSwap<T>(BuildContext context, Value<T> result) {
    if (_modalStack.isEmpty) return;
    final top = _modalStack.last;
    // Remember the top so the next push() drops it from underneath the incoming
    // modal in a single frame, but leave it on the stack and displayed for now.
    _retainedForSwap = top;
    // Complete the awaiting run() so the caller proceeds to open the next modal.
    // Don't touch the stack or notifier: the display must not change yet.
    if (!result.present) {
      top.completeAbsent();
    } else if (top is _ModalStackItem<T>) {
      if (!top.completer.isCompleted) top.completer.complete(result);
    } else {
      top.completeAbsent();
    }
  }

  void pop<T>(BuildContext context, Value<T> result) {
    if (_modalStack.isEmpty) return;

    final stackItem = _modalStack.removeLast();
    if (identical(stackItem, _retainedForSwap)) _retainedForSwap = null;
    // Check if this is the last modal BEFORE completing the completer,
    // because completing may trigger a cascade of pops that empties the stack
    final shouldCloseDialog = _modalStack.isEmpty;

    // Complete the completer - this may synchronously trigger more pops
    // For absent values, use completeAbsent() to avoid type mismatches.
    // A popForSwap'd item may already be completed; guard against re-completing.
    if (!result.present) {
      stackItem.completeAbsent();
    } else if (stackItem is _ModalStackItem<T>) {
      if (!stackItem.completer.isCompleted) stackItem.completer.complete(result);
    } else {
      // The top stack item expects a different generic type than the caller is
      // popping with — typically because a nested modal (e.g. a FormModal<
      // CommandReturn>) is still on top when the outer modal tries to pop with
      // its own T. Casting via dynamic doesn't help: Completer<Value<X>>.
      // complete still runtime-checks the argument against X. Complete the
      // mismatched item as absent rather than crashing.
      stackItem.completeAbsent();
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
        // Pop without a typed result — the modal's return value flows
        // through stackItem.completer. Passing result directly can throw
        // when nested modals have a different T than the route's T.
        navigator.pop();
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
    if (identical(stackItem, _retainedForSwap)) _retainedForSwap = null;
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
        navigator.pop();
      } else {
        log.warning('Cannot pop - navigator says canPop is false');
      }
    } else if (_modalStack.isNotEmpty) {
      _notifyStackChanged();
    }
  }

  Future<void> popAll(BuildContext context) async {
    _retainedForSwap = null;
    while (_modalStack.isNotEmpty) {
      final stackItem = _modalStack.removeLast();
      stackItem.completeAbsent();
    }
    // Use the same context that was used to create the dialog
    final modalContext = _rootContextKey.currentContext ?? context;
    final navigator = Navigator.of(
      modalContext,
      rootNavigator: _usedRootNavigator,
    );
    // Use pop() directly instead of maybePop(). maybePop() checks PopScope's
    // canPop which reads from _modalStackNotifier — but we cleared the stack
    // without updating the notifier, so canPop is stale and maybePop becomes
    // a no-op, leaving the dialog open on the navigator forever.
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  void _notifyStackChanged() {
    if (!mounted) return;
    _modalStackNotifier.value = _modalStack.length;
    _hasOpenModalsNotifier.value = hasOpenModals;
  }

  @override
  Widget build(BuildContext context) {
    final inherited = _ModalProviderInherited._(
      modalStack: _modalStack,
      modalStackNotifier: _modalStackNotifier,
      state: this,
      child: Container(key: _rootContextKey, child: widget.child),
    );
    _inherited = inherited;
    // The outermost provider (no ancestor provider) is the global fallback for
    // contexts outside any ModalProvider subtree. getElementFor… doesn't create
    // a dependency, so this is safe to read during build.
    if (context
            .getElementForInheritedWidgetOfExactType<_ModalProviderInherited>() ==
        null) {
      _root = this;
    }
    return inherited;
  }

  @override
  void dispose() {
    _activeProviders.remove(this);
    if (identical(_root, this)) _root = null;
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

  void popForSwap<T>(BuildContext context, Value<T> result) {
    state.popForSwap<T>(context, result);
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

  // Guarded: a popForSwap'd item is completed while still on the stack, so a
  // later drain/dismiss of the same item must not re-complete it.
  void completeAbsent() {
    if (!completer.isCompleted) completer.complete(Value.absent());
  }
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
            child: ExcludeFocus(
              excluding: i != widget.modalStack.length - 1,
              child: widget.modalStack[i].modal,
            ),
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

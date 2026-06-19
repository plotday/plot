import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/form_button_bar.dart';
import 'package:plot/widget/list_view_selector.dart';
import 'package:plot/widget/scroll_edge_fade.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/style/spacing.dart';
import 'icon.dart';
import 'modal.dart';
import 'logging.dart';

class FormModal extends Modal {
  factory FormModal(
    FormData form, {
    required List<StaticFormGroup> groups,
    required BuildContext rootContext,
    BoxConstraints? constraints,
    double? maxWidthPercentage,
  }) {
    // Cache the _FormModal widget so it's not recreated on modal rebuilds
    final formModal = _FormModal(
      form,
      groups: groups,
      rootContext: rootContext,
    );
    return FormModal._(formModal, form, constraints, maxWidthPercentage);
  }

  FormModal._(
    Widget formModal,
    FormData form,
    BoxConstraints? constraints,
    double? maxWidthPercentage,
  ) : super(
        padding: const EdgeInsets.all(0),
        builder: (_) => formModal,
        key: ObjectKey(form),
        constraints:
            constraints ?? const BoxConstraints(maxHeight: 640, maxWidth: 750),
        maxWidthPercentage: maxWidthPercentage ?? 0.8,
        showCloseButton: form.dismissable,
      );

  Future<CommandReturn> run(BuildContext context) {
    return super
        .show<CommandReturn>(context)
        .then((value) => value.present ? value.value : const CommandSkipped());
  }

  /// Collapses each group's maximal *trailing* run of [FormButton]s (absorbing
  /// any [FormDivider]s interleaved with or adjacent to that run) into a single
  /// [FormButtonBar]. A [FormButton] that is not part of the trailing run
  /// (e.g. a mid-form `Add account`) is left untouched. Pure — does not mutate
  /// the input.
  static List<StaticFormGroup> groupTrailingButtons(
    List<StaticFormGroup> groups,
  ) {
    return groups.map((group) {
      final items = group.items;
      // Find the start of the trailing run: items that are FormButton or
      // FormDivider, scanning from the end.
      int runStart = items.length;
      while (runStart > 0 &&
          (items[runStart - 1] is FormButton ||
              items[runStart - 1] is FormDivider)) {
        runStart--;
      }
      final tail = items.sublist(runStart);
      final buttons = tail.whereType<FormButton>().toList();
      // No trailing buttons (e.g. empty group, or only non-button items) →
      // leave the group as-is.
      if (buttons.isEmpty) return group;
      final head = items.sublist(0, runStart);
      return StaticFormGroup(
        title: group.title,
        subtitle: group.subtitle,
        items: [
          ...head,
          FormButtonBar(
            key: '${group.title ?? 'actions'}__bar',
            buttons: buttons,
          ),
        ],
      );
    }).toList();
  }
}

class _FormModal extends StatefulWidget {
  const _FormModal(
    this.form, {
    required this.groups,
    required this.rootContext,
  });

  final FormData form;
  final List<StaticFormGroup> groups;
  final BuildContext rootContext;

  @override
  FormModalState createState() => FormModalState();
}

class FormModalState extends State<_FormModal> {
  List<StaticFormGroup> _formGroups = [];
  List<FocusNode> _focusNodes = [];
  int _highlightedIndex = 0; // Track highlighted item for keyboard navigation
  bool _mouseHasMoved = false;
  final Map<FormButton, FormButtonController> _buttonControllers = {};
  final ScrollController _scrollController = ScrollController();
  int _lastModalStackDepth = 0;
  ValueNotifier<int>? _modalStackNotifier;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _initForm();
    widget.form.refreshOn?.addListener(_onExternalRefresh);
  }

  /// External trigger (e.g. a subscription change) asked the form to rebuild.
  /// Re-runs [onRefresh] so build-time gates (e.g. the "Upgrade to add more
  /// connections" button) re-evaluate against the new state. Deferred to a
  /// post-frame callback so it coalesces with any in-flight build.
  void _onExternalRefresh() {
    if (!mounted || widget.form.onRefresh == null) return;
    final restoreIndex = _highlightedIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshForm(restoreFocusIndex: restoreIndex);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = ModalProvider.of(context).modalStackNotifier;
    _lastModalStackDepth = notifier.value;
    _modalStackNotifier?.removeListener(_onModalStackChanged);
    _modalStackNotifier = notifier;
    notifier.addListener(_onModalStackChanged);
  }

  void _onModalStackChanged() {
    final newDepth = _modalStackNotifier!.value;
    final previousDepth = _lastModalStackDepth;
    _lastModalStackDepth = newDepth;

    // A child modal was popped — restore focus and optionally refresh form.
    // Defer so FormSelect.activate can set its value before we snapshot
    // current values for the refresh.
    if (newDepth < previousDepth && mounted) {
      final restoreIndex = _highlightedIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.form.onRefresh != null) {
          _refreshForm(restoreFocusIndex: restoreIndex);
        } else if (restoreIndex < _focusNodes.length) {
          _focusNodes[restoreIndex].requestFocus();
        }
      });
    }
  }

  void _teardownItems() {
    for (var group in _formGroups) {
      for (var item in group.items) {
        item.removeChangeListener(_onFormChanged);
        if (item is FormTextInput) {
          item.controller.removeListener(_onFormChanged);
        } else if (item is FormSelect) {
          item.removeListener(_onFormChanged);
        } else if (item is FormToggle) {
          item.removeListener(_onFormChanged);
        } else if (item is FormWindowList) {
          item.removeListener(_onFormChanged);
        } else if (item is FormChannelList) {
          item.removeListener(_onFormChanged);
        }
      }
    }
  }

  Future<void> _refreshForm({int? restoreFocusIndex}) async {
    final onRefresh = widget.form.onRefresh;
    if (onRefresh == null) return;
    // Guard against overlapping refreshes (e.g. a child-modal pop and an
    // external refreshOn firing in the same frame): two concurrent runs would
    // tear down and dispose the same focus nodes twice.
    if (_refreshing) return;
    _refreshing = true;
    try {
      await _doRefreshForm(restoreFocusIndex: restoreFocusIndex);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _doRefreshForm({int? restoreFocusIndex}) async {
    final onRefresh = widget.form.onRefresh;
    if (onRefresh == null) return;

    // Capture current values before tearing down old items so user edits
    // aren't lost when the form rebuilds with server-fetched defaults.
    // For FormSelect items, only save if the user explicitly changed the value
    // (not just initialized from server data) to avoid restoring stale
    // references (e.g. a deleted provider ID).
    final savedValues = <String, (dynamic,)>{};
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (item is FormSelect && !item.userModified) continue;
        savedValues[item.key] = (item.getValue(),);
      }
    }

    final newGroups = await onRefresh();
    if (!mounted) return;
    _teardownItems();
    for (var node in _focusNodes) {
      node.dispose();
    }

    // Restore values into new items that match by key
    for (var group in newGroups) {
      for (var item in group.items) {
        final saved = savedValues[item.key];
        if (saved != null) {
          item.setValue(saved.$1);
          // Carry over userModified so subsequent refreshes preserve this value
          if (item is FormSelect) {
            item.userModified = true;
          }
        }
      }
    }

    _initForm(newGroups);
    // Restore focus to the item that was highlighted before refresh
    if (restoreFocusIndex != null && restoreFocusIndex < _focusNodes.length) {
      _highlightedIndex = restoreFocusIndex;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.form.refreshOn?.removeListener(_onExternalRefresh);
    _modalStackNotifier?.removeListener(_onModalStackChanged);
    _teardownItems();
    // Dispose focus nodes
    for (var node in _focusNodes) {
      node.dispose();
    }
    _scrollController.dispose();
    super.dispose();
  }

  void _initForm([List<StaticFormGroup>? groups]) {
    _formGroups = FormModal.groupTrailingButtons(groups ?? widget.groups);

    // Create focus nodes — one per focusable sub-item
    final totalCount = _allFocusSlotsCount();
    _focusNodes = List.generate(totalCount, (_) => FocusNode());

    // Find initial focus index based on form state
    _highlightedIndex = _findInitialFocusIndex();

    // Wire up onSubmitted for text inputs and add listeners for form state
    // changes. The primary button is set explicitly on each FormButton via
    // its `isPrimary` flag — there is no auto-assignment.
    for (var group in _formGroups) {
      for (var item in group.items) {
        item.addChangeListener(_onFormChanged);
        item.onSubmitted = _submitForm;
        if (item is FormTextInput) {
          item.controller.addListener(_onFormChanged);
        } else if (item is FormSelect) {
          item.addListener(_onFormChanged);
        } else if (item is FormToggle) {
          item.addListener(_onFormChanged);
        } else if (item is FormWindowList) {
          item.addListener(_onFormChanged);
        } else if (item is FormChannelList) {
          item.addListener(_onFormChanged);
        }
      }
    }

    // Request focus on determined item after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_focusNodes.isNotEmpty &&
          mounted &&
          _highlightedIndex < _focusNodes.length) {
        log.fine('Initial focus request on item (index $_highlightedIndex)');
        _focusNodes[_highlightedIndex].requestFocus();
      }
    });
  }

  int _findInitialFocusIndex() {
    final totalSlots = _allFocusSlotsCount();

    // First, look for first empty required field
    for (int i = 0; i < totalSlots; i++) {
      final (item, _) = _getItemAndSubIndex(i);
      if (item.required && !item.isValid() && _isFocusSlotEnabled(i)) {
        return i;
      }
    }

    // If all required fields are filled, find first text input
    for (int i = 0; i < totalSlots; i++) {
      final (item, _) = _getItemAndSubIndex(i);
      if (item is FormTextInput && _isFocusSlotEnabled(i)) {
        return i;
      }
    }

    // No text inputs, find primary button first (standalone or inside a bar)
    for (int i = 0; i < totalSlots; i++) {
      final (item, subIndex) = _getItemAndSubIndex(i);
      if (item is FormButton && item.isPrimary && _isFocusSlotEnabled(i)) {
        return i;
      }
      if (item is FormButtonBar &&
          item.primarySubIndex == subIndex &&
          _isFocusSlotEnabled(i)) {
        return i;
      }
    }

    // Fall back to first button (standalone or any bar slot)
    for (int i = 0; i < totalSlots; i++) {
      final (item, _) = _getItemAndSubIndex(i);
      if ((item is FormButton || item is FormButtonBar) &&
          _isFocusSlotEnabled(i)) {
        return i;
      }
    }

    // Fallback to first enabled slot
    for (int i = 0; i < totalSlots; i++) {
      if (_isFocusSlotEnabled(i)) {
        return i;
      }
    }

    return 0;
  }

  void _onFormChanged() {
    if (mounted) {
      setState(() {
        // Sync focus nodes if the total count changed (e.g., window added/removed)
        final newTotal = _allFocusSlotsCount();
        if (newTotal != _focusNodes.length) {
          // Dispose excess nodes
          for (int i = newTotal; i < _focusNodes.length; i++) {
            _focusNodes[i].dispose();
          }
          // Add new nodes if needed
          if (newTotal > _focusNodes.length) {
            _focusNodes = [
              ..._focusNodes,
              ...List.generate(
                newTotal - _focusNodes.length,
                (_) => FocusNode(),
              ),
            ];
          } else {
            _focusNodes = _focusNodes.sublist(0, newTotal);
          }
          // Clamp highlighted index
          if (_highlightedIndex >= newTotal && newTotal > 0) {
            _highlightedIndex = newTotal - 1;
          }
        }

        // If the currently highlighted slot is disabled, move to the nearest enabled one
        if (newTotal > 0 && !_isFocusSlotEnabled(_highlightedIndex)) {
          // Try moving down first
          int candidate = _highlightedIndex + 1;
          while (candidate < newTotal && !_isFocusSlotEnabled(candidate)) {
            candidate++;
          }

          // If no enabled slot below, try moving up
          if (candidate >= newTotal) {
            candidate = _highlightedIndex - 1;
            while (candidate >= 0 && !_isFocusSlotEnabled(candidate)) {
              candidate--;
            }
          }

          // Update highlight if we found an enabled slot
          if (candidate >= 0 && candidate < newTotal) {
            _highlightedIndex = candidate;
            if (_highlightedIndex < _focusNodes.length) {
              _focusNodes[_highlightedIndex].requestFocus();
            }
          }
        }
      });
    }
  }

  /// Total number of focus slots across all items (respects focusableCount).
  int _allFocusSlotsCount() {
    int total = 0;
    for (var group in _formGroups) {
      for (var item in group.items) {
        total += item.focusableCount;
      }
    }
    return total;
  }

  /// Total number of items (for rendering — each FormItem is one rendered row).
  int _allItemsCount() {
    return _formGroups.fold(0, (total, group) => total + group.items.length);
  }

  /// Maps a flat focus slot index to (FormItem, subIndex within that item).
  (FormItem, int) _getItemAndSubIndex(int focusIndex) {
    int slot = 0;
    for (var group in _formGroups) {
      for (var item in group.items) {
        final count = item.focusableCount;
        if (focusIndex < slot + count) {
          return (item, focusIndex - slot);
        }
        slot += count;
      }
    }
    throw RangeError('Focus index $focusIndex out of range');
  }

  /// Returns the starting focus slot index for a given item index.
  int _focusSlotForItemIndex(int itemIndex) {
    int slot = 0;
    int currentItem = 0;
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (currentItem == itemIndex) return slot;
        slot += item.focusableCount;
        currentItem++;
      }
    }
    throw RangeError('Item index $itemIndex out of range');
  }

  bool _isFocusSlotEnabled(int focusIndex) {
    final (item, subIndex) = _getItemAndSubIndex(focusIndex);
    if (!item.isFocusable) return false;
    if (item is FormButton) return item.skipValidation || _isFormValid();
    if (item is FormButtonBar) {
      return item.isSubSlotEnabled(subIndex, _isFormValid());
    }
    if (item is FormSelect) return item.enabled;
    return true;
  }

  void _moveHighlight(int offset) {
    setState(() {
      final totalSlots = _allFocusSlotsCount();
      if (totalSlots == 0) return;

      int newIndex = _highlightedIndex;
      final step = offset > 0 ? 1 : -1;

      // Move by offset, skipping disabled slots
      for (int i = 0; i < offset.abs(); i++) {
        int candidate = newIndex + step;

        // Keep moving in the same direction until we find an enabled slot
        while (candidate >= 0 && candidate < totalSlots) {
          if (_isFocusSlotEnabled(candidate)) {
            newIndex = candidate;
            break;
          }
          candidate += step;
        }

        // If we couldn't find an enabled slot, stop here
        if (candidate < 0 || candidate >= totalSlots) {
          break;
        }
      }

      _highlightedIndex = newIndex;
    });

    // Request focus on the new highlighted slot
    if (_highlightedIndex < _focusNodes.length) {
      _focusNodes[_highlightedIndex].requestFocus();
    }
    _scrollToIndex(_highlightedIndex);
  }

  /// Scrolls to ensure the item at the given index is visible.
  /// Only scrolls if the item is outside or near the viewport edges.
  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      const estimatedItemHeight = 50.0;

      // Special case: scroll to top for first item to show headers/info
      if (index == 0) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        return;
      }

      final estimatedOffset = index * estimatedItemHeight;
      final viewportHeight = _scrollController.position.viewportDimension;
      final currentScroll = _scrollController.offset;
      final maxScroll = _scrollController.position.maxScrollExtent;

      // Check if item is above visible area
      if (estimatedOffset < currentScroll) {
        _scrollController.animateTo(
          estimatedOffset,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
      // Check if item (+ next item for look-ahead) is below visible area
      else if (estimatedOffset + (estimatedItemHeight * 2) >
          currentScroll + viewportHeight) {
        final targetScroll =
            (estimatedOffset + (estimatedItemHeight * 2) - viewportHeight)
                .clamp(0.0, maxScroll);
        _scrollController.animateTo(
          targetScroll,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Whether the very last rendered item is a [FormButtonBar] — in which case
  /// the action bar sits flush against the modal's bottom edge (no trailing
  /// gap), so its label is vertically centred in the whole bottom section.
  bool _lastItemIsButtonBar() {
    for (var g = _formGroups.length - 1; g >= 0; g--) {
      final items = _formGroups[g].items;
      if (items.isNotEmpty) return items.last is FormButtonBar;
    }
    return false;
  }

  FormItem _getItemAtIndex(int index) {
    int currentIndex = 0;
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (currentIndex == index) {
          return item;
        }
        currentIndex++;
      }
    }
    throw RangeError('Index $index out of range');
  }

  StaticFormGroup _getGroupAtIndex(int index) {
    int currentIndex = 0;
    for (var group in _formGroups) {
      for (var _ in group.items) {
        if (currentIndex == index) {
          return group;
        }
        currentIndex++;
      }
    }
    throw RangeError('Index $index out of range');
  }

  /// Check if all required fields are valid
  bool _isFormValid() {
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (!item.isValid()) {
          return false;
        }
      }
    }
    return true;
  }

  /// Collect all form values into a map
  Map<String, dynamic> _collectFormValues() {
    final Map<String, dynamic> values = {};
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (item is! FormButton && item is! FormButtonBar) {
          values[item.key] = item.getValue();
        }
      }
    }
    return values;
  }

  /// Execute form submission (triggered by Enter key from text inputs):
  /// run the primary button, whether standalone or inside a [FormButtonBar].
  Future<void> _submitForm() async {
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (item is FormButton && item.isPrimary) {
          await _buttonControllers[item]?.run();
          return;
        }
        if (item is FormButtonBar) {
          final controller = item.primaryController;
          if (controller != null) {
            await controller.run();
            return;
          }
        }
      }
    }
  }

  void _cancel() {
    Modal.pop<CommandReturn>(context, Value.absent());
  }

  @override
  Widget build(BuildContext context) {
    final totalItemCount = _allItemsCount();

    return ListViewSelector(
      key: ValueKey(totalItemCount),
      onActivate: (index) async {
        if (index >= _allFocusSlotsCount()) return;
        final (item, subIndex) = _getItemAndSubIndex(index);
        if (item is FormButtonBar) {
          // Run the specific button highlighted within the bar.
          await item.runSubSlot(subIndex);
        } else if (item is FormButton || item.onSubmitted != null) {
          // Enter key triggers form submission (primary button)
          await _submitForm();
        }
      },
      builder: (context, listController) {
        // Set bounds for the controller
        listController.clamp(0, totalItemCount - 1);

        return Focus(
          skipTraversal: true,
          canRequestFocus: false,
          onKeyEvent: (node, event) {
            // Intercept Tab/Shift-Tab to handle custom navigation
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.tab) {
                final isShiftPressed =
                    HardwareKeyboard.instance.logicalKeysPressed.contains(
                      LogicalKeyboardKey.shiftLeft,
                    ) ||
                    HardwareKeyboard.instance.logicalKeysPressed.contains(
                      LogicalKeyboardKey.shiftRight,
                    );
                if (isShiftPressed) {
                  _moveHighlight(-1);
                } else {
                  _moveHighlight(1);
                }
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                  event.logicalKey == LogicalKeyboardKey.arrowDown) {
                final isShiftPressed =
                    HardwareKeyboard.instance.logicalKeysPressed.contains(
                      LogicalKeyboardKey.shiftLeft,
                    ) ||
                    HardwareKeyboard.instance.logicalKeysPressed.contains(
                      LogicalKeyboardKey.shiftRight,
                    );
                if (!isShiftPressed) {
                  _moveHighlight(
                    event.logicalKey == LogicalKeyboardKey.arrowUp ? -1 : 1,
                  );
                  return KeyEventResult.handled;
                }
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                  event.logicalKey == LogicalKeyboardKey.arrowRight) {
                // Only hijack ←/→ when the highlighted slot is inside a button
                // bar (its buttons render side-by-side in multi-panel).
                // Elsewhere ←/→ stay available as text-cursor keys.
                if (_allFocusSlotsCount() > 0) {
                  final (item, _) = _getItemAndSubIndex(_highlightedIndex);
                  if (item is FormButtonBar) {
                    _moveHighlight(
                      event.logicalKey == LogicalKeyboardKey.arrowLeft ? -1 : 1,
                    );
                    return KeyEventResult.handled;
                  }
                }
              }
            }
            return KeyEventResult.ignored;
          },
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.arrowUp):
                  MoveListSelectionIntent(-1),
              SingleActivator(LogicalKeyboardKey.arrowDown):
                  MoveListSelectionIntent(1),
              SingleActivator(LogicalKeyboardKey.tab): MoveListSelectionIntent(
                1,
              ),
              SingleActivator(LogicalKeyboardKey.tab, shift: true):
                  MoveListSelectionIntent(-1),
              SingleActivator(LogicalKeyboardKey.enter):
                  ActivateListSelectionIntent(),
              SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
            },
            child: Actions(
              actions: {
                MoveListSelectionIntent:
                    CallbackAction<MoveListSelectionIntent>(
                      onInvoke: (intent) {
                        _moveHighlight(intent.offset);
                        return KeyEventResult.handled;
                      },
                    ),
                ActivateListSelectionIntent: CallbackAction<ActivateListSelectionIntent>(
                  onInvoke: (intent) {
                    if (_allFocusSlotsCount() > 0) {
                      final (item, subIndex) = _getItemAndSubIndex(
                        _highlightedIndex,
                      );
                      if (item is FormButton) {
                        // Run the specific button that's focused
                        final controller = _buttonControllers[item];
                        if (controller != null) {
                          controller.run();
                        }
                      } else if (item is FormButtonBar) {
                        // Run the specific button highlighted within the bar
                        item.runSubSlot(subIndex);
                      } else if (item.onSubmitted != null) {
                        // For text inputs, trigger primary button (first button)
                        _submitForm();
                      } else if (item.canActivate) {
                        final indexToRestore = _highlightedIndex;
                        log.info(
                          'Activatable item activated, will restore to index $indexToRestore',
                        );
                        item.activate(context, subIndex: subIndex).then((_) {
                          log.info(
                            'Item.activate returned, scheduling focus restore',
                          );
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            log.info(
                              'Post-frame callback: mounted=$mounted, indexToRestore=$indexToRestore, focusNodes.length=${_focusNodes.length}',
                            );
                            if (mounted &&
                                indexToRestore < _focusNodes.length) {
                              final node = _focusNodes[indexToRestore];
                              log.info(
                                'Requesting focus on node: hasFocus=${node.hasFocus}, canRequestFocus=${node.canRequestFocus}',
                              );
                              node.requestFocus();
                              log.info(
                                'After requestFocus: hasFocus=${node.hasFocus}',
                              );
                            }
                          });
                        });
                      }
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
                DismissIntent: CallbackAction<DismissIntent>(
                  onInvoke: (intent) {
                    _cancel();
                    return KeyEventResult.handled;
                  },
                ),
              },
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Calculate available height for content (reserve space for header + padding)
                  final headerHeight = 60.0; // Approximate header height
                  final availableContentHeight =
                      constraints.maxHeight - headerHeight - 16.0;

                  return FormScope(
                    values: _collectFormValues(),
                    validate: _isFormValid,
                    refresh: widget.form.onRefresh != null
                        ? _refreshForm
                        : null,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Title header
                        Container(
                          padding: context.theme.spacing.padding,
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: context.theme.colors.border,
                                width: 1,
                              ),
                            ),
                          ),
                          child: ValueListenableBuilder<int>(
                            valueListenable: ModalProvider.of(
                              context,
                            ).modalStackNotifier,
                            builder: (context, stackLength, _) => Row(
                              children: [
                                if (stackLength > 1)
                                  FButton.icon(
                                    variant: FButtonVariant.ghost,
                                    onPress: () => Modal.pop<CommandReturn>(
                                      context,
                                      Value.absent(),
                                    ),
                                    child: Icon(
                                      PlotIcon.left,
                                      size: context.theme.iconSizes.sm,
                                    ),
                                  ),
                                Expanded(
                                  child: Padding(
                                    // Reserve space so the floating close
                                    // button (rendered by Modal) doesn't
                                    // overlap the title text.
                                    padding: EdgeInsets.only(
                                      right: stackLength <= 1
                                          ? modalCloseButtonReservedWidth
                                          : 0,
                                    ),
                                    child: Text(
                                      widget.form.title,
                                      style: context.theme.typography.md
                                          .copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // Content list - constrained to available height
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: availableContentHeight,
                          ),
                          child: ScrollEdgeFade(
                            background: context.theme.colors.background,
                            child: ListView.builder(
                              controller: _scrollController,
                              shrinkWrap: true,
                              itemCount: totalItemCount,
                              itemBuilder: (context, index) {
                                final group = _getGroupAtIndex(index);
                                final item = _getItemAtIndex(index);
                                Widget? header;

                                if (group.title != null &&
                                    (index == 0 ||
                                        group != _getGroupAtIndex(index - 1))) {
                                  // Section heading: outranks field labels via
                                  // foreground colour + semibold weight (labels
                                  // stay muted). Any right-aligned subtitle is
                                  // secondary meta, so it stays muted.
                                  final headingStyle = context
                                      .theme
                                      .typography
                                      .sm
                                      .copyWith(
                                        color:
                                            context.theme.colors.foreground,
                                        fontWeight: FontWeight.w600,
                                      );
                                  final subtitleStyle = context
                                      .theme
                                      .typography
                                      .sm
                                      .copyWith(
                                        color: context
                                            .theme
                                            .colors
                                            .mutedForeground,
                                      );
                                  header = Padding(
                                    // Generous space above separates the
                                    // section from the previous block; tight
                                    // below so the heading hugs its items. The
                                    // first group sits under the modal header,
                                    // so it needs no extra top.
                                    padding: EdgeInsets.only(
                                      left: context.theme.spacing.xl,
                                      right: context.theme.spacing.xl,
                                      top: index == 0
                                          ? context.theme.spacing.sm
                                          : context.theme.spacing.lg,
                                      bottom: context.theme.spacing.xs,
                                    ),
                                    child: group.subtitle != null
                                        ? Row(
                                            children: [
                                              Text(
                                                group.title!,
                                                style: headingStyle,
                                              ),
                                              const Spacer(),
                                              Text(
                                                group.subtitle!,
                                                style: subtitleStyle,
                                              ),
                                            ],
                                          )
                                        : Text(
                                            group.title!,
                                            style: headingStyle,
                                          ),
                                  );
                                }

                                // Map item index to focus slot range
                                final focusSlotStart = _focusSlotForItemIndex(
                                  index,
                                );
                                final focusCount = item.focusableCount;

                                // Determine which sub-item is highlighted (-1 = none)
                                final int highlightedSubIndex;
                                if (hasPhysicalKeyboard() &&
                                    _highlightedIndex >= focusSlotStart &&
                                    _highlightedIndex <
                                        focusSlotStart + focusCount) {
                                  highlightedSubIndex =
                                      _highlightedIndex - focusSlotStart;
                                } else {
                                  highlightedSubIndex = -1;
                                }

                                // Slice of focus nodes for this item
                                final itemFocusNodes =
                                    focusSlotStart < _focusNodes.length
                                    ? _focusNodes.sublist(
                                        focusSlotStart,
                                        (focusSlotStart + focusCount).clamp(
                                          0,
                                          _focusNodes.length,
                                        ),
                                      )
                                    : <FocusNode>[];

                                return GestureDetector(
                                  onTap: () async {
                                    final item = _getItemAtIndex(index);
                                    // Items with multiple focusable sub-items handle
                                    // their own taps via ListTile commands
                                    if (item.canActivate &&
                                        item.focusableCount <= 1) {
                                      await item.activate(context);
                                    }
                                  },
                                  child: MouseRegion(
                                    cursor: SystemMouseCursors.basic,
                                    onEnter: (_) {
                                      if (_mouseHasMoved) {
                                        listController.setHovered(index);
                                      }
                                    },
                                    onExit: (_) {
                                      if (_mouseHasMoved) {
                                        listController.setHovered(null);
                                      }
                                    },
                                    onHover: (_) {
                                      if (!_mouseHasMoved) {
                                        setState(() => _mouseHasMoved = true);
                                        listController.setHovered(index);
                                      }
                                    },
                                    child: Column(
                                      key: ValueKey(index),
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        ?header,
                                        item.build(
                                          context,
                                          highlightedSubIndex,
                                          enabled: item is FormButton
                                              ? (item.skipValidation ||
                                                    _isFormValid())
                                              : item is FormButtonBar
                                              ? _isFormValid()
                                              : true,
                                          focusNodes: itemFocusNodes,
                                          controller: item is FormButton
                                              ? _buttonControllers.putIfAbsent(
                                                  item,
                                                  () => FormButtonController(),
                                                )
                                              : null,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        // A trailing button bar fills flush to the modal's
                        // bottom edge (its own symmetric padding centres the
                        // label); other content keeps a bottom breathing gap.
                        if (!_lastItemIsButtonBar())
                          SizedBox(height: context.theme.spacing.md),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

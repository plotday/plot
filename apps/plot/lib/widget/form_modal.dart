import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/list_view_selector.dart';
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
  }) {
    // Cache the _FormModal widget so it's not recreated on modal rebuilds
    final formModal = _FormModal(
      form,
      groups: groups,
      rootContext: rootContext,
    );
    return FormModal._(formModal, form);
  }

  FormModal._(Widget formModal, FormData form)
    : super(
        padding: const EdgeInsets.all(0),
        builder: (_) => formModal,
        key: ObjectKey(form),
      );

  Future<CommandReturn> run(BuildContext context) {
    return super
        .show<CommandReturn>(context)
        .then((value) => value.present ? value.value : const CommandSkipped());
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

  @override
  void initState() {
    super.initState();
    _initForm();
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

    // A child modal was popped — restore focus to our highlighted item
    if (newDepth < previousDepth && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _highlightedIndex < _focusNodes.length) {
          _focusNodes[_highlightedIndex].requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _modalStackNotifier?.removeListener(_onModalStackChanged);
    // Remove listeners from text input controllers and select fields
    // Note: We don't dispose the controllers here because the FormItem instances
    // might be reused if another dialog (like SelectBar) was on top and closes.
    // The FormItems are owned by the FormData, not by FormBarState.
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (item is FormTextInput) {
          item.controller.removeListener(_onFormChanged);
        } else if (item is FormSelect) {
          item.removeListener(_onFormChanged);
        }
      }
    }
    // Dispose focus nodes
    for (var node in _focusNodes) {
      node.dispose();
    }
    _scrollController.dispose();
    super.dispose();
  }

  void _initForm() {
    _formGroups = widget.groups;

    // Create focus nodes for each item
    final totalCount = _formGroups.fold(
      0,
      (total, group) => total + group.items.length,
    );
    _focusNodes = List.generate(totalCount, (_) => FocusNode());

    // Find initial focus index based on form state
    _highlightedIndex = _findInitialFocusIndex();

    // Wire up onSubmitted for text inputs, isPrimary for first button,
    // and add listeners for form state changes
    bool foundPrimaryButton = false;
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (item is FormTextInput) {
          item.onSubmitted = _submitForm;
          item.controller.addListener(_onFormChanged);
        } else if (item is FormSelect) {
          item.addListener(_onFormChanged);
        } else if (item is FormButton && !foundPrimaryButton) {
          item.isPrimary = true;
          foundPrimaryButton = true;
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
    final totalCount = _allItemsCount();

    // First, look for first empty required field
    for (int i = 0; i < totalCount; i++) {
      final item = _getItemAtIndex(i);
      if (item.required && !item.isValid() && _isItemEnabled(i)) {
        return i;
      }
    }

    // If all required fields are filled, find first text input
    for (int i = 0; i < totalCount; i++) {
      final item = _getItemAtIndex(i);
      if (item is FormTextInput && _isItemEnabled(i)) {
        return i;
      }
    }

    // No text inputs, find first button
    for (int i = 0; i < totalCount; i++) {
      final item = _getItemAtIndex(i);
      if (item is FormButton && _isItemEnabled(i)) {
        return i;
      }
    }

    // Fallback to first enabled item
    for (int i = 0; i < totalCount; i++) {
      if (_isItemEnabled(i)) {
        return i;
      }
    }

    return 0;
  }

  void _onFormChanged() {
    if (mounted) {
      setState(() {
        // Rebuild to update button enabled state
        // If the currently highlighted item is now disabled, move to the nearest enabled item
        if (!_isItemEnabled(_highlightedIndex)) {
          final totalCount = _allItemsCount();

          // Try moving down first
          int candidate = _highlightedIndex + 1;
          while (candidate < totalCount && !_isItemEnabled(candidate)) {
            candidate++;
          }

          // If no enabled item below, try moving up
          if (candidate >= totalCount) {
            candidate = _highlightedIndex - 1;
            while (candidate >= 0 && !_isItemEnabled(candidate)) {
              candidate--;
            }
          }

          // Update highlight if we found an enabled item
          if (candidate >= 0 && candidate < totalCount) {
            _highlightedIndex = candidate;
            if (_highlightedIndex < _focusNodes.length) {
              _focusNodes[_highlightedIndex].requestFocus();
            }
          }
        }
      });
    }
  }

  int _allItemsCount() {
    return _formGroups.fold(0, (total, group) => total + group.items.length);
  }

  bool _isItemEnabled(int index) {
    final item = _getItemAtIndex(index);
    // Skip non-focusable items (e.g., FormInfo, FormDivider)
    if (!item.isFocusable) {
      return false;
    }
    if (item is FormButton) {
      return _isFormValid();
    }
    if (item is FormSelect) {
      return item.enabled;
    }
    return true;
  }

  void _moveHighlight(int offset) {
    setState(() {
      final totalCount = _allItemsCount();
      if (totalCount == 0) return;

      int newIndex = _highlightedIndex;
      final step = offset > 0 ? 1 : -1;

      // Move by offset, skipping disabled items
      for (int i = 0; i < offset.abs(); i++) {
        int candidate = newIndex + step;

        // Keep moving in the same direction until we find an enabled item
        while (candidate >= 0 && candidate < totalCount) {
          if (_isItemEnabled(candidate)) {
            newIndex = candidate;
            break;
          }
          candidate += step;
        }

        // If we couldn't find an enabled item, stop here
        if (candidate < 0 || candidate >= totalCount) {
          break;
        }
      }

      _highlightedIndex = newIndex;
    });

    // Request focus on the new highlighted item
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
        if (item is! FormButton) {
          values[item.key] = item.getValue();
        }
      }
    }
    return values;
  }

  /// Find the first button (primary button)
  FormButton? _getPrimaryButton() {
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (item is FormButton) {
          return item;
        }
      }
    }
    return null;
  }

  /// Execute form submission (triggered by Enter key from text inputs)
  Future<void> _submitForm() async {
    // Find and run the primary (first) button's controller
    final primaryButton = _getPrimaryButton();
    if (primaryButton != null) {
      final controller = _buttonControllers[primaryButton];
      if (controller != null) {
        await controller.run();
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
        final item = _getItemAtIndex(index);
        if (item is FormButton || item is FormTextInput) {
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
              if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                _moveHighlight(-1);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                _moveHighlight(1);
                return KeyEventResult.handled;
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
                    if (_allItemsCount() > 0) {
                      final item = _getItemAtIndex(_highlightedIndex);
                      if (item is FormButton) {
                        // Run the specific button that's focused
                        final controller = _buttonControllers[item];
                        if (controller != null) {
                          controller.run();
                        }
                      } else if (item is FormTextInput) {
                        // For text inputs, trigger primary button (first button)
                        _submitForm();
                      } else if (item.canActivate) {
                        final indexToRestore = _highlightedIndex;
                        log.info(
                          'Activatable item activated, will restore to index $indexToRestore',
                        );
                        item.activate(context).then((_) {
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
                                    style: FButtonStyle.ghost(),
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
                                  child: Text(
                                    widget.form.title,
                                    style: context.theme.typography.base
                                        .copyWith(fontWeight: FontWeight.w600),
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
                                header = Padding(
                                  padding: context.theme.spacing.paddingSm,
                                  child: Text(
                                    group.title!,
                                    style: TextStyle(
                                      color:
                                          context.theme.colors.mutedForeground,
                                      fontSize:
                                          context.theme.typography.sm.fontSize,
                                    ),
                                  ),
                                );
                              }

                              return GestureDetector(
                                onTap: () async {
                                  final item = _getItemAtIndex(index);
                                  // FormButton handles its own taps via ListTile
                                  if (item.canActivate) {
                                    await item.activate(context);
                                  }
                                },
                                child: MouseRegion(
                                  cursor:
                                      item is FormButton || item.canActivate
                                      ? SystemMouseCursors.click
                                      : SystemMouseCursors.basic,
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
                                      if (header != null) header,
                                      item.build(
                                        context,
                                        index == _highlightedIndex &&
                                            hasPhysicalKeyboard(),
                                        enabled: item is FormButton
                                            ? _isFormValid()
                                            : true,
                                        focusNode: index < _focusNodes.length
                                            ? _focusNodes[index]
                                            : null,
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

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/widget/list_view_selector.dart';
import 'package:plot/style/layout.dart';
import 'dialog.dart';
import 'logging.dart';

class FormBar extends Dialog {
  factory FormBar(
    FormData form, {
    required List<StaticFormGroup> groups,
    required BuildContext rootContext,
  }) {
    // Cache the _FormBar widget so it's not recreated on dialog rebuilds
    final formBar = _FormBar(form, groups: groups, rootContext: rootContext);
    return FormBar._(formBar, form);
  }

  FormBar._(Widget formBar, FormData form)
    : super(
        padding: const EdgeInsets.all(0),
        builder: (_) => formBar,
        key: ObjectKey(form),
      );

  Future<CommandReturn> run(BuildContext context) {
    return super
        .show<CommandReturn>(context)
        .then((value) => value.present ? value.value : const CommandSkipped());
  }
}

class _FormBar extends StatefulWidget {
  const _FormBar(this.form, {required this.groups, required this.rootContext});

  final FormData form;
  final List<StaticFormGroup> groups;
  final BuildContext rootContext;

  @override
  FormBarState createState() => FormBarState();
}

class FormBarState extends State<_FormBar> {
  List<StaticFormGroup> _formGroups = [];
  List<FocusNode> _focusNodes = [];
  String? _error;
  int _highlightedIndex = 0; // Track highlighted item for keyboard navigation

  @override
  void initState() {
    super.initState();
    _initForm();
  }

  @override
  void dispose() {
    // Remove listeners from text input controllers
    // Note: We don't dispose the controllers here because the FormItem instances
    // might be reused if another dialog (like SelectBar) was on top and closes.
    // The FormItems are owned by the FormData, not by FormBarState.
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (item is FormTextInput) {
          item.controller.removeListener(_onFormChanged);
        }
      }
    }
    // Dispose focus nodes
    for (var node in _focusNodes) {
      node.dispose();
    }
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

    // Find first enabled item for initial focus
    _highlightedIndex = 0;
    for (int i = 0; i < totalCount; i++) {
      if (_isItemEnabled(i)) {
        _highlightedIndex = i;
        break;
      }
    }

    // Add listeners to all text input controllers to rebuild on changes
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (item is FormTextInput) {
          item.controller.addListener(_onFormChanged);
        }
      }
    }

    // Request focus on first item after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_focusNodes.isNotEmpty && mounted) {
        log.info('Initial focus request on first item (index 0)');
        _focusNodes[0].requestFocus();
      }
    });
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

  /// Execute form submission (triggered by Enter key or button click)
  Future<void> _submitForm() async {
    if (!_isFormValid()) {
      setState(() {
        _error = 'Please fill in all required fields';
      });
      return;
    }

    final primaryButton = _getPrimaryButton();
    if (primaryButton == null || primaryButton.onSubmit == null) {
      return;
    }

    setState(() {
      _error = null;
    });

    try {
      final values = _collectFormValues();
      final result = await primaryButton.onSubmit!(widget.rootContext, values);

      if (!mounted) return;

      if (result is CommandMessage && result.isError) {
        setState(() {
          _error = result.message;
        });
        return;
      }

      Dialog.popAll(context);
      if (context.mounted && result is CommandRoute) {
        result.go(widget.rootContext);
      }
    } catch (e, stackTrace) {
      log.warning('Error submitting form', e, stackTrace);
      if (mounted) {
        setState(() {
          _error = 'Something went wrong';
        });
      }
    }
  }

  /// Execute a specific button action
  Future<CommandReturn> _executeButton(FormButton button) async {
    if (!_isFormValid()) {
      setState(() {
        _error = 'Please fill in all required fields';
      });
      return const CommandDone();
    }

    setState(() {
      _error = null;
    });

    try {
      if (button.onSubmit != null) {
        final values = _collectFormValues();
        final result = await button.onSubmit!(widget.rootContext, values);

        if (!mounted) return const CommandSkipped();

        if (result is CommandMessage && result.isError) {
          setState(() {
            _error = result.message;
          });
          return const CommandDone();
        }

        Dialog.popAll(context);
        if (context.mounted && result is CommandRoute) {
          result.go(widget.rootContext);
        }
        return result;
      } else {
        // Fallback to action's run method
        final result = await button.command.run(widget.rootContext);
        if (!mounted) return const CommandSkipped();

        if (result is CommandMessage && result.isError) {
          setState(() {
            _error = result.message;
          });
          return const CommandDone();
        }

        Dialog.popAll(context);
        if (context.mounted && result is CommandRoute) {
          result.go(widget.rootContext);
        }
        return result;
      }
    } catch (e, stackTrace) {
      log.warning('Error executing button', e, stackTrace);
      if (mounted) {
        setState(() {
          _error = 'Something went wrong';
        });
      }
    }
    return const CommandDone();
  }

  @override
  Widget build(BuildContext context) {
    Widget? errorBox;
    if (_error != null) {
      errorBox = Container(
        padding: const EdgeInsets.all(8),
        child: Text(_error!),
      );
    }

    final totalItemCount = _allItemsCount();

    return ListViewSelector(
      key: ValueKey(totalItemCount),
      onActivate: (index) async {
        final item = _getItemAtIndex(index);
        if (item is FormButton) {
          await _executeButton(item);
        } else if (item is FormTextInput) {
          // Enter key in text input triggers form submission
          await _submitForm();
        }
      },
      builder: (context, listController) {
        // Set bounds for the controller
        listController.clamp(0, totalItemCount - 1);

        return Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowUp):
                MoveListSelectionIntent(-1),
            SingleActivator(LogicalKeyboardKey.arrowDown):
                MoveListSelectionIntent(1),
            SingleActivator(LogicalKeyboardKey.enter):
                ActivateListSelectionIntent(),
          },
          child: Actions(
            actions: {
              MoveListSelectionIntent: CallbackAction<MoveListSelectionIntent>(
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
                      if (_isFormValid()) {
                        _executeButton(item);
                      }
                    } else if (item is FormTextInput) {
                      _submitForm();
                    } else if (item is FormSelect) {
                      final indexToRestore = _highlightedIndex;
                      log.info(
                        'FormSelect activated, will restore to index $indexToRestore',
                      );
                      item.activate(context).then((_) {
                        log.info(
                          'FormSelect.activate returned, scheduling focus restore',
                        );
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          log.info(
                            'Post-frame callback: mounted=$mounted, indexToRestore=$indexToRestore, focusNodes.length=${_focusNodes.length}',
                          );
                          if (mounted && indexToRestore < _focusNodes.length) {
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
            },
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Title header
                  Container(
                    padding: widgetPadding,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: context.theme.colors.border,
                          width: 1,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.form.title,
                            style: context.theme.typography.base.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (errorBox != null) errorBox,
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight - 100,
                    ),
                    child: ListView.builder(
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
                            padding: widgetPaddingSm,
                            child: Text(
                              group.title!,
                              style: TextStyle(
                                color: context.theme.colors.mutedForeground,
                                fontSize: context.theme.typography.xs.fontSize,
                              ),
                            ),
                          );
                        }

                        return MouseRegion(
                          onEnter: (_) => listController.setHovered(index),
                          onExit: (_) => listController.setHovered(null),
                          child: Column(
                            key: ValueKey(index),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (header != null) header,
                              item.build(
                                context,
                                index == _highlightedIndex,
                                enabled: item is FormButton
                                    ? _isFormValid()
                                    : true,
                                focusNode: index < _focusNodes.length
                                    ? _focusNodes[index]
                                    : null,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

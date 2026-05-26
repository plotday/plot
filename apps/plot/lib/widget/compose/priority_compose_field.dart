import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// Either an existing priority or the synthetic "Auto-organize" choice.
sealed class PriorityChoice {
  String get label;
}

/// Synthetic choice that flips the draft into auto-organize mode.
class AutoOrganizeChoice implements PriorityChoice {
  const AutoOrganizeChoice();
  @override
  String get label => 'Auto';
}

/// Wraps an existing [Priority] as a [PriorityChoice].
class PickedPriorityChoice implements PriorityChoice {
  const PickedPriorityChoice(this.priority);
  final Priority priority;
  @override
  String get label => priority.title;
}

/// Compose-surface priority field. Renders as a ghost text field: shows
/// the selected priority (or "Auto") when unfocused, and a borderless
/// filter input + popover dropdown when focused. Selection commits and
/// blurs the field.
class PriorityComposeField extends StatefulWidget {
  const PriorityComposeField({
    super.key,
    required this.currentPriority,
    required this.isAuto,
    required this.onPickAuto,
    required this.onPickPriority,
    required this.openTouchModal,
  });

  /// Currently selected priority (irrelevant when [isAuto] is true).
  final Priority currentPriority;

  /// True when the draft is in auto-organize mode.
  final bool isAuto;

  /// Switch to auto-organize.
  final Future<void> Function() onPickAuto;

  /// Switch to a specific priority.
  final Future<void> Function(Priority next) onPickPriority;

  /// On touch, tapping the field invokes this to open the existing
  /// SelectModal. NewThreadPage owns the modal helper.
  final Future<void> Function() openTouchModal;

  @override
  State<PriorityComposeField> createState() => _PriorityComposeFieldState();
}

class _PriorityComposeFieldState extends State<PriorityComposeField> {
  final DropdownController _dropdown = DropdownController();
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _controller = TextEditingController();
  final GlobalKey<ComposeDropdownState<PriorityChoice>> _dropdownKey =
      GlobalKey<ComposeDropdownState<PriorityChoice>>();
  List<Priority> _allPriorities = const [];
  List<PriorityChoice> _candidates = const [];

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
    _controller.addListener(_refreshCandidates);
    _loadPriorities();
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _controller.removeListener(_refreshCandidates);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadPriorities() async {
    final all = await Priority.get(order: PriorityOrder.nested);
    if (!mounted) return;
    setState(() {
      _allPriorities = all;
      _refreshCandidates();
    });
  }

  void _refreshCandidates() {
    final query = _controller.text.trim().toLowerCase();
    final next = <PriorityChoice>[];
    if (!widget.isAuto && (query.isEmpty || 'auto'.contains(query))) {
      next.add(const AutoOrganizeChoice());
    }
    for (final p in _allPriorities) {
      if (query.isEmpty || p.matchesSearch(_controller.text)) {
        next.add(PickedPriorityChoice(p));
      }
    }
    setState(() => _candidates = next);
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus && hasPhysicalKeyboard()) {
      _refreshCandidates();
      _dropdown.show();
    } else {
      _dropdown.hide();
      // Reset the filter so the next focus starts from the full list.
      if (_controller.text.isNotEmpty) _controller.clear();
    }
  }

  Future<void> _handlePicked(PriorityChoice choice) async {
    _controller.clear();
    _focusNode.unfocus();
    _dropdown.hide();
    if (choice is AutoOrganizeChoice) {
      await widget.onPickAuto();
    } else if (choice is PickedPriorityChoice) {
      await widget.onPickPriority(choice.priority);
    }
  }

  Future<void> _handleTap() async {
    if (hasPhysicalKeyboard()) {
      _focusNode.requestFocus();
    } else {
      await widget.openTouchModal();
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final state = _dropdownKey.currentState;
    if (state == null) return KeyEventResult.ignored;
    return state.handleKey(event)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    // Match the FTextField's md typography so the row height is the same
    // whether the value label or the input is showing.
    final fontSize = theme.typography.md.fontSize;
    final valueLabel = widget.isAuto
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(PlotIcon.sparkles, size: theme.iconSizes.sm),
              const SizedBox(width: 6),
              const Text('Auto'),
            ],
          )
        : PriorityLabel(
            priority: widget.currentPriority,
            fontSize: fontSize,
          );

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKey,
      child: ComposeFieldRow(
        icon: FontAwesomeIcons.folder,
        tooltip: 'Priority',
        shortcut: platformSingleActivator(
          LogicalKeyboardKey.keyP,
          shift: true,
        ),
        onTapField: _handleTap,
        child: ComposeDropdown<PriorityChoice>(
          key: _dropdownKey,
          controller: _dropdown,
          autoFocusOnShow: false,
          items: _candidates,
          itemBuilder: (context, choice, highlighted) {
            return Container(
              color: highlighted ? theme.plotColors.highlight : null,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              child: switch (choice) {
                AutoOrganizeChoice() => Row(
                    children: [
                      Icon(PlotIcon.sparkles, size: theme.iconSizes.sm),
                      const SizedBox(width: 8),
                      const Text('Auto-organize'),
                    ],
                  ),
                PickedPriorityChoice() => PriorityLabel(
                    priority: choice.priority,
                    fontSize: fontSize,
                  ),
              },
            );
          },
          onSelected: _handlePicked,
          child: ComposeValueInput(
            controller: _controller,
            focusNode: _focusNode,
            hint: 'Select priority',
            value: valueLabel,
            readOnly: isTouchPlatform(),
          ),
        ),
      ),
    );
  }
}

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

/// Compose-surface priority field. Reads the resolved priority (or "Auto"),
/// opens a focus-driven dropdown on desktop, or the touch modal on tap.
class PriorityComposeField extends StatefulWidget {
  const PriorityComposeField({
    super.key,
    required this.currentPriority,
    required this.isAuto,
    required this.onPickAuto,
    required this.onPickPriority,
    required this.openTouchModal,
    this.isLast = false,
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

  final bool isLast;

  @override
  State<PriorityComposeField> createState() => _PriorityComposeFieldState();
}

class _PriorityComposeFieldState extends State<PriorityComposeField> {
  final DropdownController _dropdown = DropdownController();
  final FocusNode _focusNode = FocusNode();
  final GlobalKey<ComposeDropdownState<PriorityChoice>> _dropdownKey =
      GlobalKey<ComposeDropdownState<PriorityChoice>>();
  List<PriorityChoice> _candidates = const [];

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus && hasPhysicalKeyboard()) {
      _loadCandidates();
      _dropdown.show();
    } else {
      _dropdown.hide();
    }
  }

  Future<void> _loadCandidates() async {
    final all = await Priority.get(order: PriorityOrder.nested);
    if (!mounted) return;
    setState(() {
      _candidates = [
        if (!widget.isAuto) const AutoOrganizeChoice(),
        ...all.map(PickedPriorityChoice.new),
      ];
    });
  }

  Future<void> _handlePicked(PriorityChoice choice) async {
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
    final fontSize = theme.typography.sm.fontSize;
    final label = widget.isAuto
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(PlotIcon.sparkles, size: theme.iconSizes.sm),
              const SizedBox(width: 6),
              Text('Auto', style: theme.typography.sm),
            ],
          )
        : PriorityLabel(
            priority: widget.currentPriority,
            fontSize: fontSize,
          );

    return ComposeFieldRow(
      icon: FontAwesomeIcons.folder,
      tooltip: 'Priority',
      shortcut: platformSingleActivator(
        LogicalKeyboardKey.keyP,
        shift: true,
      ),
      onTapField: _handleTap,
      isLast: widget.isLast,
      child: ComposeDropdown<PriorityChoice>(
        key: _dropdownKey,
        controller: _dropdown,
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
        child: Focus(
          focusNode: _focusNode,
          onKeyEvent: _handleKey,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: label,
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

// --- Chip value ---

/// One value currently shown as a chip in the contacts field.
sealed class ContactChipValue {
  String get key;
  String get label;
}

/// A chip backed by a known [Actor] (contact or twist).
class ContactChipActor implements ContactChipValue {
  ContactChipActor(this.actor);
  final Actor actor;
  @override
  String get key => 'actor:${actor.id.toUuid()}';
  @override
  String get label => actor.name ?? actor.email ?? 'Unknown';
}

/// A chip backed by a known [GroupRow].
class ContactChipGroup implements ContactChipValue {
  ContactChipGroup(this.group);
  final GroupRow group;
  @override
  String get key => 'group:${group.id}';
  @override
  String get label => group.name;
}

/// A chip backed by a raw email address (invite, not yet a known contact).
class ContactChipEmail implements ContactChipValue {
  ContactChipEmail(this.email);
  final String email;
  @override
  String get key => 'email:$email';
  @override
  String get label => email;
}

// --- Candidate ---

/// One row in the autocomplete dropdown.
sealed class ContactCandidate {
  String get label;
}

/// A known [Actor] as a candidate.
class ActorCandidate implements ContactCandidate {
  ActorCandidate(this.actor);
  final Actor actor;
  @override
  String get label => actor.name ?? actor.email ?? '';
}

/// A known [GroupRow] as a candidate.
class GroupCandidate implements ContactCandidate {
  GroupCandidate(this.group);
  final GroupRow group;
  @override
  String get label => group.name;
}

/// A raw email address shown as "Invite {email}" in the dropdown.
class InviteEmailCandidate implements ContactCandidate {
  InviteEmailCandidate(this.email);
  final String email;
  @override
  String get label => 'Invite $email';
}

// --- Widget ---

/// Chip+text hybrid field for sharing/contact selection in the compose
/// surface. Renders chips for selected contacts, an inline text input for
/// search/type-ahead, and a floating dropdown of candidates. Supports:
///
/// - Keyboard chip navigation (arrow keys, backspace/delete to remove)
/// - Email-pattern auto-commit (Enter, comma)
/// - Tab to accept first candidate
/// - Click/tap chip-action menu (remove, future: CC/BCC)
/// - Touch: tapping the row opens [openTouchModal] instead of keyboard flow
class ContactsComposeField extends StatefulWidget {
  const ContactsComposeField({
    super.key,
    required this.chips,
    required this.loadCandidates,
    required this.onAdd,
    required this.onRemove,
    required this.openTouchModal,
    this.isLast = false,
  });

  /// Currently selected chips.
  final List<ContactChipValue> chips;

  /// Returns candidates filtered by [query], with already-selected values
  /// excluded. Callers append [InviteEmailCandidate] when [query] is an
  /// email pattern not already on the chip list.
  final Future<List<ContactCandidate>> Function(String query) loadCandidates;

  /// Persist adding a candidate as a chip.
  final Future<void> Function(ContactCandidate candidate) onAdd;

  /// Persist removing a chip.
  final Future<void> Function(ContactChipValue chip) onRemove;

  /// On touch platforms, open a full-screen contacts picker modal. The page
  /// owns this helper.
  final Future<void> Function() openTouchModal;

  final bool isLast;

  @override
  State<ContactsComposeField> createState() => ContactsComposeFieldState();
}

class ContactsComposeFieldState extends State<ContactsComposeField> {
  final DropdownController _dropdown = DropdownController();
  final FocusNode _inputFocus = FocusNode();
  final GlobalKey<ComposeDropdownState<ContactCandidate>> _dropdownKey =
      GlobalKey<ComposeDropdownState<ContactCandidate>>();
  late final TextEditingController _controller;
  List<ContactCandidate> _candidates = const [];
  int? _focusedChipIndex;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _inputFocus.addListener(_handleFocusChange);
    _controller.addListener(_handleTextChange);
  }

  @override
  void dispose() {
    _inputFocus.removeListener(_handleFocusChange);
    _controller.removeListener(_handleTextChange);
    _inputFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_inputFocus.hasFocus && hasPhysicalKeyboard()) {
      _refreshCandidates();
      _dropdown.show();
    } else {
      _dropdown.hide();
    }
  }

  void _handleTextChange() {
    if (_controller.text.isNotEmpty && _focusedChipIndex != null) {
      setState(() => _focusedChipIndex = null);
    }
    _refreshCandidates();
  }

  Future<void> _refreshCandidates() async {
    final results = await widget.loadCandidates(_controller.text);
    if (!mounted) return;
    setState(() => _candidates = results);
  }

  Future<void> _handlePicked(ContactCandidate candidate) async {
    await widget.onAdd(candidate);
    _controller.clear();
    _refreshCandidates();
  }

  Future<void> _commitTypedEmail() async {
    final text = EmailParser.normalize(_controller.text);
    if (!EmailParser.isEmail(text)) return;
    await widget.onAdd(InviteEmailCandidate(text));
    _controller.clear();
    _refreshCandidates();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // Let the dropdown consume arrows/Enter first when items are present.
    final dropdownState = _dropdownKey.currentState;
    if (dropdownState != null && _controller.text.isNotEmpty) {
      if (dropdownState.handleKey(event)) {
        return KeyEventResult.handled;
      }
    }

    final isEmpty = _controller.text.isEmpty;

    // Chip navigation only when the input is empty.
    if (isEmpty) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        if (widget.chips.isEmpty) return KeyEventResult.ignored;
        setState(() {
          _focusedChipIndex =
              (_focusedChipIndex ?? widget.chips.length) - 1;
          if (_focusedChipIndex! < 0) {
            _focusedChipIndex = widget.chips.length - 1;
          }
        });
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        if (_focusedChipIndex == null) return KeyEventResult.ignored;
        setState(() {
          final next = _focusedChipIndex! + 1;
          _focusedChipIndex = next >= widget.chips.length ? null : next;
        });
        return KeyEventResult.handled;
      }
      // Backspace or Delete on a focused chip → remove it.
      if ((event.logicalKey == LogicalKeyboardKey.backspace ||
              event.logicalKey == LogicalKeyboardKey.delete) &&
          _focusedChipIndex != null) {
        final idx = _focusedChipIndex!;
        if (idx < widget.chips.length) {
          widget.onRemove(widget.chips[idx]);
          setState(() {
            _focusedChipIndex = idx == 0 ? null : idx - 1;
          });
        }
        return KeyEventResult.handled;
      }
      // Backspace in empty input with no chip focused → focus the last chip.
      if (event.logicalKey == LogicalKeyboardKey.backspace &&
          widget.chips.isNotEmpty &&
          _focusedChipIndex == null) {
        setState(() => _focusedChipIndex = widget.chips.length - 1);
        return KeyEventResult.handled;
      }
    }

    // Tab commits the first candidate (treat as accept), or is ignored when
    // no candidates so focus traversal can proceed normally.
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (_candidates.isNotEmpty) {
        _handlePicked(_candidates.first);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Enter/comma with email-format text → commit as invite.
    if ((event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter ||
            event.logicalKey == LogicalKeyboardKey.comma) &&
        EmailParser.isEmail(_controller.text)) {
      _commitTypedEmail();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _handleChipTap(int idx) async {
    final action = await showComposeChipMenu(
      context,
      chipLabel: widget.chips[idx].label,
    );
    if (action == ComposeChipAction.remove) {
      await widget.onRemove(widget.chips[idx]);
    }
  }

  Future<void> _handleRowTap() async {
    if (hasPhysicalKeyboard()) {
      _inputFocus.requestFocus();
    } else {
      await widget.openTouchModal();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final placeholder = widget.chips.isEmpty ? 'Private — only you' : '';

    return ComposeFieldRow(
      icon: FontAwesomeIcons.user,
      tooltip: 'Share with',
      shortcut: platformSingleActivator(
        LogicalKeyboardKey.keyS,
        shift: true,
      ),
      onTapField: _handleRowTap,
      isLast: widget.isLast,
      child: ComposeDropdown<ContactCandidate>(
        key: _dropdownKey,
        controller: _dropdown,
        items: _candidates,
        itemBuilder: (context, candidate, highlighted) {
          return Container(
            color: highlighted ? theme.plotColors.highlight : null,
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            child: Text(candidate.label),
          );
        },
        onSelected: _handlePicked,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              for (var i = 0; i < widget.chips.length; i++)
                _ChipView(
                  value: widget.chips[i],
                  focused: i == _focusedChipIndex,
                  onTap: () => _handleChipTap(i),
                ),
              IntrinsicWidth(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 80),
                  child: Focus(
                    onKeyEvent: _handleKey,
                    child: FTextField(
                      control: .managed(controller: _controller),
                      focusNode: _inputFocus,
                      readOnly: isTouchPlatform(),
                      hint: placeholder,
                      style: FTextFieldStyleDelta.delta(
                        contentPadding: EdgeInsetsGeometryDelta.value(
                          const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChipView extends StatelessWidget {
  const _ChipView({
    required this.value,
    required this.focused,
    required this.onTap,
  });

  final ContactChipValue value;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final color = focused
        ? theme.colors.primary
        : theme.plotColors.muted;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: focused ? 0.2 : 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          value.label,
          style: theme.typography.sm,
        ),
      ),
    );
  }
}

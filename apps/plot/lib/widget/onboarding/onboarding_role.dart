import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/widget/onboarding/onboarding_hoverable.dart';

/// The role choices offered by the onboarding "Where do you want to use Plot
/// first?" step. Each maps to a label, an optional follow-up prompt, and the
/// resulting role name (see [RoleOptionMeta]).
enum RoleOption { work, personal, volunteering, school, other }

/// A tiny mutable holder shared between the role step's `contentBuilder` (which
/// writes the user's selection) and its `onBeforeNext` (which reads it to name
/// the default role). One instance per onboarding session — `OnboardingSteps.all`
/// is built once in `OnboardingBloc.start()`, so this object persists across
/// rebuilds and step changes for the life of the flow.
class OnboardingRoleSelection {
  /// The currently selected option. Defaults to [RoleOption.personal] so a user
  /// who taps Next without choosing still gets a sensible single-role name.
  RoleOption option = RoleOption.personal;

  /// The text typed into the option's follow-up field (e.g. the workplace name).
  /// Ignored for options without a prompt (Personal, School).
  String text = '';
}

/// Labels, follow-up prompts, and the resulting role name for each
/// [RoleOption]. Kept out of the enum body so the enum stays a plain value.
extension RoleOptionMeta on RoleOption {
  /// The option-card label shown in the picker.
  String get label => switch (this) {
    RoleOption.work => 'Work',
    RoleOption.personal => 'Personal',
    RoleOption.volunteering => 'Volunteering',
    RoleOption.school => 'School',
    RoleOption.other => 'Other',
  };

  /// The follow-up field's label, or null when the option needs no follow-up
  /// (Personal and School name the role from the label alone).
  String? get prompt => switch (this) {
    RoleOption.work => 'Where do you work?',
    RoleOption.volunteering => 'Where do you volunteer?',
    RoleOption.other => 'What should we call this role?',
    _ => null,
  };

  /// The follow-up field's placeholder hint. Null mirrors [prompt].
  String? get placeholder => switch (this) {
    RoleOption.work => 'Acme Co',
    RoleOption.volunteering => 'The Kindness Project',
    RoleOption.other => 'Superhero',
    _ => null,
  };

  /// The resulting role name given the typed [text]. Personal and School use a
  /// fixed name; the prompted options use the trimmed answer, falling back to
  /// the option [label] when the user left the field blank. Always returns a
  /// non-empty name, so Next can proceed without a hard validation gate.
  String roleName(String text) {
    final t = text.trim();
    return switch (this) {
      RoleOption.personal => 'Personal',
      RoleOption.school => 'School',
      _ => t.isNotEmpty ? t : label,
    };
  }
}

/// The interactive content for the onboarding role step: a single-select list
/// of [RoleOption] cards plus a conditional follow-up text field. Writes the
/// user's choice into the shared [selection] holder; the step's `onBeforeNext`
/// reads it to name the user's default role.
///
/// Self-contained (no Bloc reads) and styled to match the onboarding aesthetic
/// — white cards on the coloured backdrop, like the connector tiles in
/// `onboarding_tools.dart`.
class OnboardingRoleContent extends StatefulWidget {
  const OnboardingRoleContent({required this.selection, super.key});

  final OnboardingRoleSelection selection;

  @override
  State<OnboardingRoleContent> createState() => _OnboardingRoleContentState();
}

class _OnboardingRoleContentState extends State<OnboardingRoleContent> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.selection.text)
      ..addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    widget.selection.text = _controller.text;
  }

  void _select(RoleOption option) {
    if (widget.selection.option == option) return;
    setState(() {
      widget.selection.option = option;
      // Clear any text carried over from a prompted option so an option
      // without a prompt (Personal/School) doesn't keep a stale answer, and a
      // newly prompted option starts empty.
      widget.selection.text = '';
      _controller.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selection.option;
    final prompt = selected.prompt;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final option in RoleOption.values) ...[
          _RoleOptionTile(
            label: option.label,
            selected: option == selected,
            onTap: () => _select(option),
          ),
          const SizedBox(height: 10),
        ],
        if (prompt != null) ...[
          const SizedBox(height: 6),
          _RolePromptField(
            label: prompt,
            placeholder: selected.placeholder ?? '',
            controller: _controller,
            focusNode: _focusNode,
          ),
        ],
      ],
    );
  }
}

/// A selectable role option card. Mirrors `_ToolTile`'s white-card hover
/// treatment; the selected card gets an accent border and tinted fill.
class _RoleOptionTile extends StatelessWidget {
  const _RoleOptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OnboardingHoverable(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFEDE9FE)
              : (hovered ? const Color(0xFFF5F3FF) : const Color(0xFFFFFFFF)),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? const Color(0xFF7C3AED)
                : const Color(0x00000000),
            width: 2,
          ),
          boxShadow: hovered && !selected
              ? const [
                  BoxShadow(
                    color: Color(0x26000000),
                    blurRadius: 12,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: const Color(0xFF1F1F1F),
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
            if (selected)
              Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: Color(0xFF7C3AED),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Icon(
                    FontAwesomeIcons.check,
                    size: 10,
                    color: Color(0xFFFFFFFF),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The conditional follow-up text input for prompted options. A white card
/// (matching the option tiles) holding a label and a bare [EditableText] so
/// the field is self-contained and doesn't pull in the app's themed input.
class _RolePromptField extends StatelessWidget {
  const _RolePromptField({
    required this.label,
    required this.placeholder,
    required this.controller,
    required this.focusNode,
  });

  final String label;
  final String placeholder;
  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 2),
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFFFFFFFF),
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              decoration: TextDecoration.none,
            ),
          ),
        ),
        // Tapping anywhere on the white card focuses the field, not just the
        // text glyphs — EditableText (unlike TextField) doesn't claim its
        // padding as a tap target on its own.
        GestureDetector(
          onTap: focusNode.requestFocus,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFFFF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Stack(
              children: [
                // Placeholder hint, shown behind the field until typing starts.
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) => value.text.isEmpty
                      ? Text(
                          placeholder,
                          style: const TextStyle(
                            color: Color(0xFF9CA3AF),
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            decoration: TextDecoration.none,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                EditableText(
                  controller: controller,
                  focusNode: focusNode,
                  style: const TextStyle(
                    color: Color(0xFF1F1F1F),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                  cursorColor: const Color(0xFF7C3AED),
                  backgroundCursorColor: const Color(0xFF9CA3AF),
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

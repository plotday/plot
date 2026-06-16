import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/widget/autofocus_reclaim.dart';
import 'package:plot/widget/onboarding/onboarding_hoverable.dart';
import 'package:plot/widget/onboarding/onboarding_step_scope.dart';

/// The role choices offered by the onboarding "Where do you want to use Plot
/// first?" step. Each maps to a label, an icon, an optional follow-up prompt,
/// and the resulting role name (see [RoleOptionMeta]).
enum RoleOption { work, project, personal, school, other }

/// A tiny mutable holder shared between the role step's `contentBuilder` (which
/// writes the user's selection) and its `onBeforeNext` (which reads it to name
/// the default role). One instance per onboarding session — `OnboardingSteps.all`
/// is built once in `OnboardingBloc.start()`, so this object persists across
/// rebuilds and step changes for the life of the flow.
class OnboardingRoleSelection {
  /// The currently selected option. Defaults to [RoleOption.personal] so a user
  /// who taps Next without choosing still gets a sensible single-role name.
  RoleOption option = RoleOption.personal;

  final ValueNotifier<String> _text = ValueNotifier<String>('');

  /// The text typed into the option's follow-up field (e.g. the workplace name).
  /// Ignored for options without a prompt (Personal, School).
  String get text => _text.value;
  set text(String value) => _text.value = value;

  /// Fires when [text] changes, so the role step's pager can reactively
  /// enable/disable Next as the user types the required name. Lives for the
  /// onboarding session (one holder per flow); not disposed, which is fine for a
  /// notifier holding only a String.
  ValueListenable<String> get textListenable => _text;
}

/// Labels, follow-up prompts, and the resulting role name for each
/// [RoleOption]. Kept out of the enum body so the enum stays a plain value.
extension RoleOptionMeta on RoleOption {
  /// The option-card label shown in the picker.
  String get label => switch (this) {
    RoleOption.work => 'Work',
    RoleOption.project => 'Project',
    RoleOption.personal => 'Personal',
    RoleOption.school => 'School',
    RoleOption.other => 'Other',
  };

  /// The leading icon shown on the option card, for a bit of visual interest.
  IconData get icon => switch (this) {
    RoleOption.work => FontAwesomeIcons.briefcase,
    RoleOption.project => FontAwesomeIcons.rocket,
    RoleOption.personal => FontAwesomeIcons.user,
    RoleOption.school => FontAwesomeIcons.graduationCap,
    RoleOption.other => FontAwesomeIcons.shapes,
  };

  /// The follow-up step's question, or null when the option needs no follow-up
  /// (Personal and School name the role from the label alone, so their
  /// follow-up step is skipped).
  String? get prompt => switch (this) {
    RoleOption.work => 'Where do you work?',
    RoleOption.project => 'What is the project?',
    RoleOption.other => 'What should we call this role?',
    _ => null,
  };

  /// The follow-up field's placeholder hint. Null mirrors [prompt].
  String? get placeholder => switch (this) {
    RoleOption.work => 'Acme Co',
    RoleOption.project => 'Website redesign',
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
/// of [RoleOption] cards. Writes the user's choice into the shared [selection]
/// holder. Options that need a typed name (Work/Project/Other) collect it on a
/// dedicated follow-up step ([OnboardingRolePromptContent]); the step's
/// `onBeforeNext` reads the selection to name the user's default role.
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
  void _select(RoleOption option) {
    if (widget.selection.option != option) {
      setState(() {
        widget.selection.option = option;
        // Clear any text carried over from a previously selected prompted
        // option so switching options never keeps a stale answer; the follow-up
        // step re-seeds its field from this (now empty) value. Re-tapping the
        // same option keeps any text already typed for it.
        widget.selection.text = '';
      });
    }
    // Advance immediately on choice rather than waiting for a Next tap.
    // Prompted options (Work/Project/Other) land on the follow-up step, whose
    // field autofocuses; unprompted options (Personal/School) skip straight to
    // the next step. The scope is absent in isolated widget tests, so guard.
    final advance = OnboardingStepScope.maybeOf(context);
    if (advance != null) unawaited(advance());
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selection.option;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final option in RoleOption.values) ...[
          _RoleOptionTile(
            label: option.label,
            icon: option.icon,
            selected: option == selected,
            onTap: () => _select(option),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// The follow-up step's content: a single autofocused text field bound to the
/// shared [selection]'s `text`. The step heading already poses the question
/// (the selected option's prompt), so there's no in-card label — just the
/// field, front and centre. Only reached for options that need a typed name
/// (Work/Project/Other); Personal/School skip this step entirely.
class OnboardingRolePromptContent extends StatefulWidget {
  const OnboardingRolePromptContent({required this.selection, super.key});

  final OnboardingRoleSelection selection;

  @override
  State<OnboardingRolePromptContent> createState() =>
      _OnboardingRolePromptContentState();
}

class _OnboardingRolePromptContentState
    extends State<OnboardingRolePromptContent> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.selection.text)
      ..addListener(_onTextChanged);
    // The onboarding overlay shares a FocusScope with the app behind it, where
    // the new-thread composer grabs focus at app start (via AutofocusReclaim).
    // Passive `autofocus` is a no-op once that scope has an owner, so claim
    // focus explicitly after mount to take it from the composer. AutofocusReclaim
    // (in build) then keeps it across the macOS/navigator focus-clearing races,
    // re-grabbing only when nobody owns it — never from a deliberate move to the
    // pager.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
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

  @override
  Widget build(BuildContext context) {
    return AutofocusReclaim(
      focusNode: _focusNode,
      autofocus: true,
      child: _RolePromptField(
        placeholder: widget.selection.option.placeholder ?? '',
        controller: _controller,
        focusNode: _focusNode,
        // Enter submits the step. Routed through the step scope's advance,
        // which is gated on the required name, so Enter is a no-op while empty.
        onSubmit: () {
          final advance = OnboardingStepScope.maybeOf(context);
          if (advance != null) unawaited(advance());
        },
      ),
    );
  }
}

/// A selectable role option card. Mirrors `_ToolTile`'s white-card hover
/// treatment; the selected card gets an accent border and tinted fill.
class _RoleOptionTile extends StatelessWidget {
  const _RoleOptionTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
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
            Icon(icon, size: 18, color: const Color(0xFF7C3AED)),
            const SizedBox(width: 14),
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

/// The follow-up text input for prompted options. A white card (matching the
/// option tiles) holding a bare [EditableText] so the field is self-contained
/// and doesn't pull in the app's themed input. Focus is driven by its parent
/// ([OnboardingRolePromptContent]) so it survives the composer-behind-overlay
/// focus contention; the step heading poses the question, so no in-card label
/// is needed.
class _RolePromptField extends StatelessWidget {
  const _RolePromptField({
    required this.placeholder,
    required this.controller,
    required this.focusNode,
    this.onSubmit,
  });

  final String placeholder;
  final TextEditingController controller;
  final FocusNode focusNode;

  /// Called when the field is submitted (Enter / keyboard "done").
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    // Tapping anywhere on the white card focuses the field, not just the text
    // glyphs — EditableText (unlike TextField) doesn't claim its padding as a
    // tap target on its own.
    return GestureDetector(
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
              onSubmitted: onSubmit == null ? null : (_) => onSubmit!(),
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
    );
  }
}

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:plot/command/base.dart';
import 'package:plot/command/priority.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/onboarding/onboarding_hoverable.dart';

/// Sample focuses surfaced as chips in the "What fills your days?" onboarding
/// step. Tapping a chip opens the focus-create modal pre-filled with these
/// values and skipping the thread-matching step (no threads are synced yet),
/// so the user can review, tweak, and create in one or two taps. The colours
/// walk the story-arc palette so the chips read as a varied set.
const List<FocusPrefill> kSampleFocuses = [
  FocusPrefill(
    title: 'Project',
    description:
        "Tasks, docs, and discussions for a project you're driving forward.",
    iconKey: 'rocket',
    color: ThemeColor(3),
  ),
  FocusPrefill(
    title: 'Management',
    description: 'One-on-ones, updates, and the people you manage.',
    iconKey: 'userGroup',
    color: ThemeColor(1),
  ),
  FocusPrefill(
    title: 'Reading',
    description: 'Articles, papers, and books you want to read.',
    iconKey: 'bookOpen',
    color: ThemeColor(2),
  ),
  FocusPrefill(
    title: 'Recruiting',
    description: 'Candidates, interviews, and your hiring pipeline.',
    iconKey: 'userMagnifyingGlass',
    color: ThemeColor(5),
  ),
  FocusPrefill(
    title: 'Admin',
    description: 'Expenses, paperwork, and operational odds and ends.',
    iconKey: 'receipt',
    color: ThemeColor(7),
  ),
  FocusPrefill(
    title: 'Personal Finance',
    description: 'Bills, budgets, investments, and money to keep an eye on.',
    iconKey: 'piggyBank',
    color: ThemeColor(0),
  ),
  FocusPrefill(
    title: 'Family',
    description: 'Plans, events, and conversations with family.',
    iconKey: 'house',
    color: ThemeColor(4),
  ),
  FocusPrefill(
    title: 'Personal',
    description: 'Errands, appointments, and personal to-dos.',
    iconKey: 'user',
    color: ThemeColor(6),
  ),
];

/// Renders the sample-focus chips for the "What fills your days?" onboarding
/// step. Each chip opens the focus-create modal pre-filled; a trailing
/// "Create anything else" chip opens an empty create modal.
///
/// The create modal layers above the onboarding overlay (which wraps the whole
/// app shell), and the navigation a successful create triggers happens beneath
/// the overlay, so the flow stays put while the user adds focuses.
class OnboardingRoles extends StatelessWidget {
  const OnboardingRoles({super.key});

  void _createFocus(BuildContext context, [FocusPrefill? prefill]) {
    unawaited(context.run(NewFocus(skipMatching: true, prefill: prefill)));
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: WrapAlignment.center,
      children: [
        for (final sample in kSampleFocuses)
          _SampleFocusChip(
            label: sample.title,
            icon: PlotIcon.focusIcon(sample.iconKey),
            onTap: () => _createFocus(context, sample),
          ),
        _SampleFocusChip(
          label: 'Create anything else',
          icon: PlotIcon.add,
          onTap: () => _createFocus(context),
        ),
      ],
    );
  }
}

/// Pill-shaped chip rendered on the colored onboarding overlay. Outlined and
/// translucent so the row reads uniformly; brightens on hover. The leading
/// icon previews the sample focus's icon (or a + for the catch-all chip).
class _SampleFocusChip extends StatelessWidget {
  const _SampleFocusChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const fg = Color(0xFFFFFFFF);
    return OnboardingHoverable(
      onTap: onTap,
      builder: (context, hovered) {
        final bg = hovered ? const Color(0x4DFFFFFF) : const Color(0x33FFFFFF);
        final borderColor =
            hovered ? const Color(0x99FFFFFF) : const Color(0x66FFFFFF);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: fg,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

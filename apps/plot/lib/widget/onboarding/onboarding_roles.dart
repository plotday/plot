import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/onboarding.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/logging.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/onboarding/onboarding_hoverable.dart';
import 'package:plot/widget/toast.dart';

/// Suggested roles surfaced in the "What fills your days?" onboarding step.
/// Each role becomes a top-level priority when committed. Multi-entry roles
/// prompt for a custom label so the user can have several priorities of the
/// same kind (e.g. "Acme Corp" and "Beta Inc" both filed under Work).
enum OnboardingRole {
  work('Work', isMulti: true, prompt: 'Where do you work?'),
  school('School', isMulti: false),
  home('Home', isMulti: false),
  social('Social', isMulti: false),
  health('Health', isMulti: false),
  hobby('Hobby', isMulti: true, prompt: 'What is your hobby?'),
  faith('Faith', isMulti: false),
  volunteering(
    'Volunteering',
    isMulti: true,
    prompt: 'Where do you volunteer?',
  ),
  other('Other', isMulti: true, prompt: 'What is your other role?');

  const OnboardingRole(this.label, {required this.isMulti, this.prompt});

  final String label;
  final bool isMulti;
  final String? prompt;
}

/// One staged selection in the roles step. May already be backed by a
/// real priority ([priorityId] non-null) or queued for creation on commit.
class RoleEntry {
  RoleEntry({required this.role, required this.label, this.priorityId});

  final OnboardingRole role;
  final String label;
  PriorityId? priorityId;
}

/// Selection state for the "What fills your days?" step.
///
/// Held on the [OnboardingBloc] so it survives back/forward step navigation.
/// Toggling and adding mutate this in memory only — DB writes happen in
/// [commit] when the user advances past the step.
class RolesStepData {
  RolesStepData({required this.entries, required this.archived});

  /// Entries the user wants to keep. Drives the visible UI.
  final List<RoleEntry> entries;

  /// Entries that were initially loaded from existing priorities but the
  /// user has since removed. Their priorities will be archived on commit.
  final List<RoleEntry> archived;

  /// Loads initial selection state from the user's existing top-level
  /// priorities. Singleton roles (those with a fixed name) are matched by
  /// title so a user revisiting onboarding sees their existing priorities
  /// already toggled on. Multi-entry priorities aren't restored here — the
  /// step doesn't store which role a custom-titled priority came from.
  static RolesStepData fromRoot(Priority? root) {
    if (root == null) {
      return RolesStepData(entries: [], archived: []);
    }
    final tops = root.children.where((p) => p.archivedAt == null).toList();
    final entries = <RoleEntry>[];
    for (final r in OnboardingRole.values) {
      if (r.isMulti) continue;
      Priority? match;
      for (final p in tops) {
        if (p.title == r.label) {
          match = p;
          break;
        }
      }
      if (match != null) {
        entries.add(RoleEntry(
          role: r,
          label: r.label,
          priorityId: match.id,
        ));
      }
    }
    return RolesStepData(entries: entries, archived: []);
  }

  /// Whether the singleton role is currently selected.
  bool isSingletonSelected(OnboardingRole role) {
    return entries.any((e) => e.role == role);
  }

  /// All entries for a multi-entry role.
  List<RoleEntry> entriesFor(OnboardingRole role) {
    return entries.where((e) => e.role == role).toList(growable: false);
  }

  /// Toggle a singleton on or off. Existing-but-removed entries are tracked
  /// in [archived] so the underlying priority is archived on commit.
  void toggleSingleton(OnboardingRole role) {
    assert(!role.isMulti);
    final existingIndex = entries.indexWhere((e) => e.role == role);
    if (existingIndex >= 0) {
      final removed = entries.removeAt(existingIndex);
      if (removed.priorityId != null) archived.add(removed);
    } else {
      // If we previously archived this role this session, restore it instead
      // of queuing a fresh create.
      final restoreIndex = archived.indexWhere((e) => e.role == role);
      if (restoreIndex >= 0) {
        entries.add(archived.removeAt(restoreIndex));
      } else {
        entries.add(RoleEntry(role: role, label: role.label));
      }
    }
  }

  /// Add a new custom entry under a multi-entry role.
  void addCustom(OnboardingRole role, String label) {
    assert(role.isMulti);
    entries.add(RoleEntry(role: role, label: label));
  }

  /// Remove a custom entry. If it was backed by an existing priority, the
  /// priority is archived on commit.
  void removeEntry(RoleEntry entry) {
    entries.remove(entry);
    if (entry.priorityId != null) archived.add(entry);
  }

  /// Persist staged changes: archive removed entries and create new ones as
  /// top-level priorities. Idempotent — calling again after success is a
  /// no-op.
  Future<void> commit() async {
    // Bail out early if Store has been torn down (sign-out racing with the
    // onboarding overlay still mounted). Without this, `Priority.getDefault`
    // below calls `Store.get` and the Injector throws a generic
    // `NotDefinedException` that gets reported as a code bug.
    if (!Store.isAvailable) {
      throw const OnboardingStoreUnavailable();
    }

    for (final e in archived) {
      final id = e.priorityId;
      if (id == null) continue;
      try {
        final p = await Priority.getOne(id);
        if (p.archivedAt == null) {
          await p.copyWith(archivedAt: Value(DateTime.now())).save();
        }
      } catch (err, stack) {
        log.warning('Failed to archive onboarding role priority $id', err, stack);
      }
    }
    archived.clear();

    final root = await Priority.getDefault();
    for (final e in entries) {
      if (e.priorityId != null) continue;
      final created = await Priority(
        parent: root,
        title: e.label,
      ).save();
      e.priorityId = created.id;
    }
  }
}

/// Entry point for the onboarding step content. Initialises [RolesStepData]
/// from the database on first build and renders the role chips.
class OnboardingRoles extends StatefulWidget {
  const OnboardingRoles({super.key});

  @override
  State<OnboardingRoles> createState() => _OnboardingRolesState();
}

class _OnboardingRolesState extends State<OnboardingRoles> {
  RolesStepData? _data;

  @override
  void initState() {
    super.initState();
    _initData();
  }

  void _initData() {
    final bloc = context.read<OnboardingBloc>();
    var data = bloc.rolesData;
    if (data == null) {
      final root = context.read<PrioritiesBloc>().state.root;
      data = RolesStepData.fromRoot(root);
      bloc.rolesData = data;
    }
    setState(() => _data = data);
  }

  Future<void> _toggleSingleton(OnboardingRole role) async {
    final data = _data;
    if (data == null) return;
    setState(() => data.toggleSingleton(role));
  }

  Future<void> _addCustom(OnboardingRole role) async {
    final data = _data;
    if (data == null) return;
    final label = await _RolePromptModal(
      title: role.prompt ?? 'Add a ${role.label.toLowerCase()}',
    ).run(context);
    if (label == null || label.isEmpty || !mounted) return;
    setState(() => data.addCustom(role, label));
  }

  void _removeEntry(RoleEntry entry) {
    final data = _data;
    if (data == null) return;
    setState(() => data.removeEntry(entry));
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      return const SizedBox(height: 80);
    }
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: WrapAlignment.center,
      children: [
        for (final role in OnboardingRole.values)
          if (role.isMulti)
            ..._buildMultiChips(role, data)
          else
            _RoleChip(
              label: role.label,
              selected: data.isSingletonSelected(role),
              onTap: () => _toggleSingleton(role),
            ),
      ],
    );
  }

  List<Widget> _buildMultiChips(OnboardingRole role, RolesStepData data) {
    final chips = <Widget>[
      for (final entry in data.entriesFor(role))
        _RoleChip(
          label: entry.label,
          selected: true,
          onTap: () => _removeEntry(entry),
        ),
      _RoleChip(
        label: role.label,
        selected: false,
        onTap: () => _addCustom(role),
      ),
    ];
    return chips;
  }
}

/// Pill-shaped chip rendered on the colored onboarding overlay.
///
/// Two visual states share the same size and shape so the row reads
/// uniformly:
/// - Unselected: outlined translucent chip with a leading + icon.
/// - Selected: filled white chip with a leading ✓ icon. Tapping toggles
///   off (singletons) or removes the staged entry (multi-entry roles).
class _RoleChip extends StatelessWidget {
  const _RoleChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? const Color(0xFF1F1F1F) : const Color(0xFFFFFFFF);
    final icon = selected ? FontAwesomeIcons.check : FontAwesomeIcons.plus;
    return OnboardingHoverable(
      onTap: onTap,
      builder: (context, hovered) {
        // Selected (white) chips deepen toward a soft tint on hover; unselected
        // translucent chips brighten by adding white alpha. Border on the
        // unselected variant brightens to match.
        final Color bg;
        if (selected) {
          bg = hovered ? const Color(0xFFF5F3FF) : const Color(0xFFFFFFFF);
        } else {
          bg = hovered ? const Color(0x4DFFFFFF) : const Color(0x33FFFFFF);
        }
        final borderColor = selected
            ? const Color(0x00000000)
            : (hovered
                ? const Color(0x99FFFFFF)
                : const Color(0x66FFFFFF));
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
                style: TextStyle(
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

/// Modal that asks the user for a custom label for a multi-entry role.
class _RolePromptModal extends Modal {
  _RolePromptModal({required String title})
      : super(
          constraints: const BoxConstraints(maxHeight: 220, maxWidth: 400),
          builder: (context) => _RolePromptContent(title: title),
        );

  Future<String?> run(BuildContext context) {
    return super
        .show<String>(context)
        .then((v) => v.present ? v.value : null);
  }
}

class _RolePromptContent extends StatefulWidget {
  const _RolePromptContent({required this.title});

  final String title;

  @override
  State<_RolePromptContent> createState() => _RolePromptContentState();
}

class _RolePromptContentState extends State<_RolePromptContent> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      context.showOverlayToast(
        message: 'Please enter a name',
        isError: true,
      );
      return;
    }
    Modal.pop<String>(context, Value<String>(value));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.title,
          style: theme.typography.md.copyWith(fontWeight: FontWeight.w600),
        ),
        SizedBox(height: theme.spacing.md),
        FTextField(
          control: .managed(controller: _controller),
          focusNode: _focusNode,
          autocorrect: false,
          onSubmit: (_) => _submit(),
        ),
        SizedBox(height: theme.spacing.md),
        Row(
          children: [
            const Spacer(),
            OnboardingHoverable(
              onTap: _submit,
              builder: (context, hovered) => AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: EdgeInsets.symmetric(
                  horizontal: theme.spacing.lg,
                  vertical: theme.spacing.sm,
                ),
                decoration: BoxDecoration(
                  color: hovered
                      ? theme.colors.hover(theme.colors.primary)
                      : theme.colors.primary,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Add',
                  style: theme.typography.sm.copyWith(
                    color: theme.colors.primaryForeground,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

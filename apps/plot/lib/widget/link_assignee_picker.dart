import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart' hide Link;

/// Selection option for the assignee picker — equality based on actor id.
class LinkAssigneeOption {
  const LinkAssigneeOption(this.id, this.name, this.email);

  final ActorId? id;
  final String name;
  final String? email;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LinkAssigneeOption && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Opens the assignee picker for [link] and writes the selected assignee
/// via [Link.updateAssignee]. No-op when the user cancels or selects the
/// current assignee.
Future<void> pickLinkAssignee(BuildContext context, Link link) async {
  final result = await SelectModal.open<LinkAssigneeOption>(
    context,
    items: (search) async {
      final actors = await Actor.get(
        search: search,
        types: [ActorType.user, ActorType.contact],
        limit: 50,
        inviteable: true,
        primary: true,
      );
      // Sort self actors to the top, preserving existing depth-based order
      actors.sort((a, b) {
        if (a.self != b.self) return a.self ? -1 : 1;
        return 0;
      });
      return [
        SelectGroup(
          items: [
            const LinkAssigneeOption(null, 'Unassigned', null),
            ...actors.map(
              (a) => LinkAssigneeOption(a.id, a.nameOrEmail, a.email),
            ),
          ],
        ),
      ];
    },
    // Wrapped in a [Builder] so the lazy [ListTile.leadingBuilder]'s
    // `context.theme` read resolves from a live context inside the sheet's own
    // tree. The caller's context can be deactivated by the time the forui sheet
    // lays out (e.g. opening the picker on a single-panel page navigates and
    // tears down the originating widget), which would otherwise throw "Looking
    // up a deactivated widget's ancestor is unsafe".
    itemBuilder: (option, _) => Builder(
      builder: (context) {
        final isSelected = option.id == link.assigneeId;
        return ListTile(
          title: option.name,
          subtitle: (option.id != null &&
                  option.email != null &&
                  option.email != option.name)
              ? option.email
              : null,
          leadingBuilder: (isHovered, hasFocus) => Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: isSelected
                ? Icon(
                    PlotIcon.done,
                    size: 14,
                    color: context.theme.colors.primary,
                  )
                : const SizedBox(width: 14),
          ),
          disableInternalHover: true,
        );
      },
    ),
    selectedValue: link.assigneeId != null
        ? LinkAssigneeOption(link.assigneeId!, '', null)
        : const LinkAssigneeOption(null, 'Unassigned', null),
    prompt: 'Assign to',
  );

  if (!result.present || !context.mounted) return;
  final newId = result.value.id;
  if (newId != link.assigneeId) {
    await Link.updateAssignee(link, newId);
  }
}

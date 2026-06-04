import 'package:flutter/widgets.dart';

import 'package:plot/command/share.dart';
import 'package:plot/store/store.dart';

/// Result of the [RecipientPickerModal]: the new per-note recipient subsets
/// plus any audience members the picker added to the thread.
///
/// - `accessContacts` / `accessGroups` are null when every thread member is
///   selected (= thread default).
/// - Otherwise they're explicit lists; `accessContacts` always includes self.
/// - `threadContactsAdded` / `threadGroupsAdded` are non-thread members the
///   user added via the picker's search — the bloc handler is responsible for
///   appending these to `thread.contacts` / `thread.groups` atomically with
///   the draft save.
class RecipientPickerResult {
  final List<String>? accessContacts;
  final List<String>? accessGroups;
  final List<String> threadContactsAdded;
  final List<String> threadGroupsAdded;

  const RecipientPickerResult({
    required this.accessContacts,
    required this.accessGroups,
    this.threadContactsAdded = const [],
    this.threadGroupsAdded = const [],
  });

  factory RecipientPickerResult.fromSelection({
    required List<String> threadContacts,
    required List<String> threadGroups,
    required Set<String> selectedContacts,
    required Set<String> selectedGroups,
    required List<String> addedContacts,
    required List<String> addedGroups,
    required String self,
  }) {
    // Did the user leave every thread contact checked?
    final allThreadContactsChecked =
        threadContacts.every(selectedContacts.contains);
    final allThreadGroupsChecked = threadGroups.every(selectedGroups.contains);

    // "thread default" = every original thread member still selected AND no
    // contacts/groups added. Adding new audience members forces an explicit
    // list because the new member needs to be persisted both per-note and on
    // the thread.
    final contactsAreDefault =
        allThreadContactsChecked && addedContacts.isEmpty;
    final groupsAreDefault = allThreadGroupsChecked && addedGroups.isEmpty;

    return RecipientPickerResult(
      accessContacts: contactsAreDefault
          ? null
          : [
              // Always include self when restricting; the toggling user must
              // be in the access list per the project's note-author constraint.
              self,
              ...selectedContacts.where((c) => c != self),
            ],
      accessGroups: groupsAreDefault ? null : selectedGroups.toList(),
      threadContactsAdded: addedContacts,
      threadGroupsAdded: addedGroups,
    );
  }

  /// Translates the final [SharedSelection] from the generic share picker back
  /// into a per-note result. [finalContacts] / [finalGroups] are the picker's
  /// resulting ids; anything in them that wasn't on the thread is treated as a
  /// newly-added audience member (written through to `thread.contacts` /
  /// `thread.groups` by the bloc handler).
  factory RecipientPickerResult.fromPickerSelection({
    required List<String> threadContacts,
    required List<String> threadGroups,
    required List<String> finalContacts,
    required List<String> finalGroups,
    required String self,
  }) {
    final threadContactSet = threadContacts.toSet();
    final threadGroupSet = threadGroups.toSet();
    final addedContacts = finalContacts
        .where((c) => !threadContactSet.contains(c))
        .toList();
    final addedGroups = finalGroups
        .where((g) => !threadGroupSet.contains(g))
        .toList();
    return RecipientPickerResult.fromSelection(
      threadContacts: threadContacts,
      threadGroups: threadGroups,
      selectedContacts: finalContacts.toSet(),
      selectedGroups: finalGroups.toSet(),
      addedContacts: addedContacts,
      addedGroups: addedGroups,
      self: self,
    );
  }

  factory RecipientPickerResult.justMe({required String self}) =>
      RecipientPickerResult(
        accessContacts: [self],
        accessGroups: const [],
      );

  factory RecipientPickerResult.replyToOriginal({
    required String self,
    required String originalAuthor,
  }) =>
      RecipientPickerResult(
        accessContacts: [self, originalAuthor],
        accessGroups: const [],
      );
}

/// Modal for picking the per-note recipient subset. Reuses the app's canonical
/// contact/group share picker ([PickShared]) — the same one the thread header's
/// Share button and the new-thread compose field use — seeded with the note's
/// current recipients. On close the resulting selection is translated into a
/// per-note subset: unchecking restricts the audience, while picking someone not
/// yet on the thread extends `thread.contacts` / `thread.groups` (via the bloc
/// handler) so the new recipient has thread access.
///
/// Note: email invites typed into the picker aren't representable in a per-note
/// subset (which keys on contact/group ids), so they're ignored here — inviting
/// a brand-new email belongs to the thread-level Share. Self is always kept in
/// the result regardless of the picker's toggle state.
class RecipientPickerModal {
  final List<String> threadContacts;
  final List<String> threadGroups;
  final List<String> initialContactSelection;
  final List<String> initialGroupSelection;
  final String self;
  final String? originalAuthor;

  /// Groups to force-offer in the picker even when the user isn't a member —
  /// the thread's non-announce groups, so a read-only viewer can narrow their
  /// reply within them. Announce groups are filtered out upstream.
  final List<String> includeGroupIds;

  const RecipientPickerModal({
    required this.threadContacts,
    required this.threadGroups,
    required this.initialContactSelection,
    required this.initialGroupSelection,
    required this.self,
    this.originalAuthor,
    this.includeGroupIds = const [],
  });

  Future<RecipientPickerResult?> run(BuildContext context) async {
    // Seed the generic share picker with the note's current recipients. The
    // picker live-edits this selection via [onUpdate]; we capture the final
    // state after the modal is dismissed and translate it below.
    var selection = SharedSelection(
      contacts: initialContactSelection.map(Uuid.fromString).toList(),
      groups: initialGroupSelection.map(Uuid.fromString).toList(),
    );
    var changed = false;

    await PickShared(
      selection: selection,
      title: 'Recipients',
      // Keep the author pinned and visible; the result always includes self
      // regardless, but injecting it avoids a confusing "self missing" row.
      injectSelf: true,
      includeGroupIds: includeGroupIds,
      onUpdate: (next) async {
        selection = next;
        changed = true;
      },
    ).run(context);

    // Dismissed without touching anything → no-op (don't re-save the draft).
    if (!changed) return null;

    return RecipientPickerResult.fromPickerSelection(
      threadContacts: threadContacts,
      threadGroups: threadGroups,
      finalContacts: selection.contacts.map((u) => u.toString()).toList(),
      finalGroups: selection.groups.map((u) => u.toString()).toList(),
      self: self,
    );
  }
}

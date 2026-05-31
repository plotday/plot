import 'package:flutter/widgets.dart';

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

/// Modal for picking the per-note recipient subset. Lists thread contacts
/// and thread groups (pre-checked), with an "Add" search to extend the
/// thread audience. Quick actions for "Just me" and "Reply to original".
///
/// The rendering layer is stubbed pending implementation of the required
/// `FormItem` subclasses (checkbox-list, search-add, quick-actions).
/// Until then, [run] returns null and callers gracefully no-op.
class RecipientPickerModal {
  final List<String> threadContacts;
  final List<String> threadGroups;
  final List<String> initialContactSelection;
  final List<String> initialGroupSelection;
  final String self;
  final String? originalAuthor;

  const RecipientPickerModal({
    required this.threadContacts,
    required this.threadGroups,
    required this.initialContactSelection,
    required this.initialGroupSelection,
    required this.self,
    this.originalAuthor,
  });

  // ignore: avoid_unused_parameters
  Future<RecipientPickerResult?> run(BuildContext context) async {
    // TODO(task-11): render via FormModal using the project's tuned variant.
    //
    // The rendering layer requires new FormItem subclasses:
    //   - RecipientCheckboxListItem: per-contact/group toggle rows (one focus
    //     slot each, canActivate → toggle), built with FormToggle-style
    //     highlight + FocusNode from the slot list.
    //   - RecipientSearchAddItem: text input that resolves contacts/groups
    //     not yet on the thread and appends them to both the selection set and
    //     addedContacts / addedGroups. Mirrors FormTextInput's onSubmitted
    //     wiring.
    //   - RecipientQuickActionItem: two non-focusable FormButton-style tiles
    //     ("Just me" / "Reply to original") that call Modal.pop<RecipientPickerResult>
    //     directly, bypassing the normal FormButton → CommandReturn path.
    //
    // The challenge: FormModal.run() returns Future<CommandReturn>, not
    // Future<RecipientPickerResult?>. To return a RecipientPickerResult the
    // implementation should either:
    //   a) Use Modal.show<RecipientPickerResult> directly (bypasses FormModal
    //      infrastructure but handles the type correctly), or
    //   b) Encode the result as a CommandDone subclass and decode on return.
    //
    // Option (a) is cleanest but requires replicating keyboard nav from
    // FormModalState. Task 12 (note_editor.dart integration) will wire this
    // up; if the rendering layer is still a stub at that point, avatar taps
    // on the NoteEditorTopBar pill simply no-op.
    return null;
  }
}

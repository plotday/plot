import 'dart:async';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

/// Add a new person to the user's address book by name + email.
///
/// Writes an optimistic local contact row and pushes it to the server.
/// The server keys contacts on the globally-unique email, so the optimistic
/// id is reused when the email is new; the rare same-email/different-id case
/// is collapsed by [ActorsBase.processPulledRows] on the next pull.
class AddContact extends Command {
  AddContact({this.name, required this.email})
    : super(
        title: 'Add contact',
        // No EventObject.contact exists; reuse `activity` like the group
        // commands do.
        eventObject: EventObject.activity,
        eventAction: EventAction.added,
      );

  final String? name;
  final String email;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final id = ActorId(Uuid.generate());
    final companion = ActorsCompanion.insert(
      id: id,
      type: ActorType.contact,
      self: false,
      name: Value(name),
      email: Value(email),
      pending: const Value(2),
    );
    await Store.get.save(Store.get.actors, companion, ActorsBase());
    // Pull the canonical row (and reconcile a same-email collapse) when
    // online; offline this is a no-op until connectivity returns.
    unawaited(SyncOrchestrator.instance.pull(SyncOrchestrator.actor));
    return CommandDone(
      message: 'Contact added',
      createdId: id.toUuid().toString(),
    );
  }
}

/// Rename a contact in the user's address book (a per-user name override).
class RenameContact extends Command {
  RenameContact({required this.contactId, required this.name})
    : super(
        title: 'Rename contact',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final ActorId contactId;
  final String name;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final Actor existing;
    try {
      existing = await Actor.getOne(contactId);
    } catch (_) {
      return const CommandMessage('Contact not found', isError: true);
    }
    if (existing.type != ActorType.contact) {
      return const CommandMessage('Not a contact', isError: true);
    }
    final updated = existing.copyWith(
      name: Value(name),
      pending: const Value(2),
    );
    await Store.get.save(Store.get.actors, updated, ActorsBase());
    return const CommandDone(message: 'Contact renamed');
  }
}

/// Edit a contact from the new-thread picker: rename only (per-user override).
/// The email is shown read-only as the form-group subtitle for context.
class EditContact extends Command {
  EditContact({
    required this.contactId,
    required this.currentName,
    this.email,
  }) : super(
          title: 'Edit contact',
          eventObject: EventObject.activity,
          eventAction: EventAction.updated,
        );

  final ActorId contactId;
  final String currentName;
  final String? email;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final items = <FormItem>[
      FormTextInput(
        key: 'name',
        label: 'Name',
        initialValue: currentName,
        placeholder: 'Name',
        required: true,
      ),
      FormButton(
        key: 'save',
        isPrimary: true,
        buildCommand: (values) {
          final name = (values['name'] as String?)?.trim() ?? '';
          return RenameContact(contactId: contactId, name: name);
        },
      ),
    ];
    final form = FormData(
      title: 'Edit contact',
      dismissable: true,
      groups: [
        StaticFormGroup(subtitle: email, items: items),
      ],
    );
    final groups = await form.list();
    if (!context.mounted) return const CommandSkipped();
    return FormModal(
      form,
      groups: groups,
      rootContext: context,
      constraints: const BoxConstraints(maxHeight: 360, maxWidth: 460),
    ).run(context);
  }
}

/// Add a new contact (name optional, email required) from the picker header.
class NewContact extends Command {
  NewContact()
    : super(
        title: 'Add contact',
        eventObject: EventObject.activity,
        eventAction: EventAction.added,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final items = <FormItem>[
      FormTextInput(
        key: 'name',
        label: 'Name',
        placeholder: 'Optional',
      ),
      FormTextInput(
        key: 'email',
        label: 'Email',
        required: true,
        placeholder: 'name@example.com',
      ),
      FormButton(
        key: 'add',
        isPrimary: true,
        buildCommand: (values) {
          final name = (values['name'] as String?)?.trim() ?? '';
          final email = (values['email'] as String?)?.trim() ?? '';
          return AddContact(name: name.isEmpty ? null : name, email: email);
        },
      ),
    ];
    final form = FormData(
      title: 'Add contact',
      dismissable: true,
      groups: [StaticFormGroup(items: items)],
    );
    final groups = await form.list();
    if (!context.mounted) return const CommandSkipped();
    return FormModal(
      form,
      groups: groups,
      rootContext: context,
      constraints: const BoxConstraints(maxHeight: 420, maxWidth: 460),
    ).run(context);
  }
}

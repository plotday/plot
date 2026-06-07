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
  AddContact({required this.name, required this.email})
    : super(
        title: 'Add contact',
        // No EventObject.contact exists; reuse `activity` like the group
        // commands do.
        eventObject: EventObject.activity,
        eventAction: EventAction.added,
      );

  final String name;
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
    return const CommandDone(message: 'Contact added');
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

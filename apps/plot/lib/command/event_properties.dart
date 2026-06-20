/// Builders that turn a composed [Note]/[Thread] into the analytics properties
/// attached to its create/send PostHog event (via [Command.eventProperties]).
///
/// The point: compose-time toggles (To-do, attachments, reply/private scope)
/// do NOT each fire their own event — instead their final state rides along as
/// properties on the single create/send event, so we can answer "what share of
/// created notes are to-dos / private / replies / have attachments" without
/// per-toggle event noise.
///
/// The decision logic lives in small pure helpers ([recipientScope],
/// [attachmentTypeNames], [composedThreadType]) that are unit-tested directly;
/// the [noteEventProperties]/[threadEventProperties] composers just read model
/// fields and assemble the map.
library;

import 'package:plot/store/store.dart';

/// Coarse audience for a composed note. Visibility-only — `is_reply` is a
/// separate property — so the values are mutually exclusive:
/// - `private`: only the author can see it.
/// - `custom`: shared with a narrowed set of contacts/groups.
/// - `everyone`: the thread's default audience (no narrowing).
String recipientScope({
  required bool isPrivate,
  required bool hasCustomAudience,
}) {
  if (isPrivate) return 'private';
  return hasCustomAudience ? 'custom' : 'everyone';
}

/// Sorted, de-duplicated attachment type names (e.g. `['external', 'file']`),
/// for the `attachment_types` event property.
List<String> attachmentTypeNames(Iterable<UserActionType> types) {
  final names = types.map((t) => t.name).toSet().toList()..sort();
  return names;
}

/// Whether a composed note carries any narrowing recipients.
bool hasCustomAudience(Note note) =>
    (note.accessContacts?.isNotEmpty ?? false) ||
    (note.accessGroups?.isNotEmpty ?? false);

/// Coarse kind of a user-composed thread. Composer threads are realistically
/// `task` (the user flagged it active) or `notes`; calendar-style events arrive
/// from connectors server-side, so scheduling is reported separately via
/// `is_scheduled` rather than folded into a fragile `event` bucket.
String composedThreadType({required bool active}) => active ? 'task' : 'notes';

/// Properties describing a composed note. `null` values are dropped by
/// [buildActionProperties], so "not applicable" keys simply don't appear.
Map<String, Object?> noteEventProperties(Note note) {
  final actions = note.actions;
  final custom = hasCustomAudience(note);
  final scope = recipientScope(
    isPrivate: note.isPrivate,
    hasCustomAudience: custom,
  );
  return {
    'is_todo': note.isAssignedTo(Base.actorId),
    'is_private': note.isPrivate,
    'is_reply': note.reNoteId != null,
    'recipient_scope': scope,
    // Only meaningful when the audience is narrowed; omit for "everyone".
    'recipient_count': scope == 'everyone'
        ? null
        : (note.accessContacts?.length ?? 0) +
              (note.accessGroups?.length ?? 0),
    'attachment_count': actions?.length ?? 0,
    'attachment_types': (actions == null || actions.isEmpty)
        ? null
        : attachmentTypeNames(actions.map((a) => a.type)),
  };
}

/// Properties describing a composed thread (and its optional first note).
Map<String, Object?> threadEventProperties(Thread thread, Note? note) {
  return {
    if (note != null) ...noteEventProperties(note),
    'contact_count': thread.contacts.length,
    'group_count': thread.groups.length,
    'thread_type': composedThreadType(active: thread.active),
    'is_scheduled': thread.at != null || thread.on != null,
    'thread_scope': thread.teamId != null ? 'team' : 'personal',
    'priority_id': thread.priority.id.toShortString(),
  };
}

import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart' show ActorId, Priority;
import 'package:plot/util/theme_color.dart' show ThemeColor;
import 'package:plot/widget/compose/compose_target.dart';

/// One recipient as it should appear on a people row.
class RecipientDisplay extends Equatable {
  const RecipientDisplay({
    required this.name,
    required this.email,
    required this.showEmail,
    this.actorId,
  });

  /// Display name (falls back to the email when there is no name).
  final String name;

  /// Full email, for the hover tooltip and the exception-only inline form.
  final String? email;

  /// Append ` <email>` inline (exception-only disambiguation).
  final bool showEmail;

  /// Resolved actor for the avatar; null for a pending invite.
  final ActorId? actorId;

  @override
  List<Object?> get props => [name, email, showEmail, actorId];
}

/// Presentation wrapper around a [ComposeTarget]: everything the row widget
/// needs that requires connection-wide / async context only the bloc has
/// (the focus tint, the disambiguated recipient list, the focus-note's focus).
class ComposeTargetView extends Equatable {
  const ComposeTargetView({
    required this.target,
    required this.header,
    required this.headerColor,
    this.recipients = const [],
    this.focusPriority,
  });

  final ComposeTarget target;

  /// Line-1 connection header text.
  final String header;

  /// Tint for the header (most-common focus for the connection; the focus's
  /// own colour for a focus-note). Resolve with
  /// `context.colour.colours.fromTheme(headerColor, muted: true)`.
  final ThemeColor headerColor;

  /// People rows only: disambiguated recipients (avatars + names + tooltip).
  final List<RecipientDisplay> recipients;

  /// Focus-note rows only: the focus to render via `FocusLabel`.
  final Priority? focusPriority;

  @override
  List<Object?> get props =>
      [target, header, headerColor, recipients, focusPriority?.id];
}

/// The grouping key a target's header tint is computed against: connector/twist
/// -> the connection (twist-instance) id; Plot chat/note -> per scope so a work
/// team's colour stays distinct from personal.
String connectionColorKey(ComposeTarget t) {
  switch (t.kind) {
    case ComposeTargetKind.connector:
    case ComposeTargetKind.twist:
      return 'conn:${t.connection?.id ?? t.target?.twist.id}';
    case ComposeTargetKind.topic:
      return 'topic:${t.topicId}';
    case ComposeTargetKind.chat:
    case ComposeTargetKind.note:
      return 'plot:${t.teamId?.toString() ?? 'personal'}';
  }
}

/// Record shape for one recipient before disambiguation.
typedef RecipientInput = ({String name, String? email, ActorId? actorId});

/// Apply the exception-only email rule: show the email beside a name only when
/// that name maps to >1 address within the connection, and only on the
/// non-primary address. [nameToEmailsForConnection] is keyed by lowercased
/// name with addresses ordered primary-first.
List<RecipientDisplay> resolveRecipientDisplays({
  required List<RecipientInput> recipients,
  required Map<String, List<String>> nameToEmailsForConnection,
}) {
  return [
    for (final r in recipients)
      RecipientDisplay(
        name: r.name,
        email: r.email,
        actorId: r.actorId,
        showEmail: _isException(r, nameToEmailsForConnection),
      ),
  ];
}

bool _isException(
  RecipientInput r,
  Map<String, List<String>> nameToEmails,
) {
  final email = r.email?.toLowerCase();
  if (email == null) return false;
  final addresses = nameToEmails[r.name.toLowerCase()];
  if (addresses == null || addresses.length < 2) return false;
  // Primary (first / most-used) stays bare; any other address is the exception.
  return addresses.first.toLowerCase() != email;
}

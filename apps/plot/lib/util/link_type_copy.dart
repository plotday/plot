import 'package:plot/store/store.dart'
    show Channel, CreateLinkUserAction, LinkTypeConfig, TwistInstance, Uuid;

/// Helpers that turn a [LinkTypeConfig] into the user-facing copy used in
/// composer placeholders and command titles. When [cfg] is null or has no
/// `noteLabel`, generic copy is returned ("Add a note", "Start a thread").
///
/// The connector populates `noteLabel` ("Comment" for Linear, "Message" for
/// Slack, "Reply" for Gmail) so the app's note/thread surfaces feel native to
/// the linked system.

String composerHintForNote(LinkTypeConfig? cfg) {
  final note = cfg?.noteLabel;
  return note != null ? 'Add a ${note.toLowerCase()}' : 'Add a note';
}

String composerHintForEditNote(LinkTypeConfig? cfg) {
  final note = cfg?.noteLabel;
  return note != null ? 'Edit ${note.toLowerCase()}' : 'Edit note';
}

String composerHintForNewThread(LinkTypeConfig? cfg) {
  if (cfg == null) return 'Start a thread';
  return 'Create a new ${cfg.label.toLowerCase()}';
}

String commandTitleAddNote(LinkTypeConfig? cfg) {
  final note = cfg?.noteLabel;
  return note != null ? 'Add ${note.toLowerCase()}' : 'Add note';
}

String commandTitleNewThread(LinkTypeConfig? cfg) {
  if (cfg == null) return 'New thread';
  return 'New ${cfg.label.toLowerCase()}';
}

String commandTitleCreateThread(LinkTypeConfig? cfg) {
  if (cfg == null) return 'Create thread';
  return 'Create ${cfg.label.toLowerCase()}';
}

/// Resolves the LinkTypeConfig referenced by a [CreateLinkUserAction] (the
/// connection target the user has selected for a draft). Prefers a
/// channel-level override, falling back to the twist-level config. Returns
/// null when the twist/channel/linkType is not in cache.
LinkTypeConfig? linkTypeConfigForCreateAction(CreateLinkUserAction? action) {
  if (action == null) return null;
  final twistId = Uuid.fromString(action.twistInstanceId);
  final channelConfigs = action.channelId != null
      ? Channel.findByChannel(twistId, action.channelId!)?.parsedLinkTypes
      : null;
  final byChannel = channelConfigs
      ?.where((c) => c.type == action.linkType)
      .firstOrNull;
  if (byChannel != null) return byChannel;
  return TwistInstance.fromCache(twistId)
      ?.parsedLinkTypes
      ?.where((c) => c.type == action.linkType)
      .firstOrNull;
}

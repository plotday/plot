import 'package:plot/store/store.dart'
    show Channel, CreateLinkUserAction, LinkTypeConfig, TwistInstance, Uuid;

/// Helpers that turn a [LinkTypeConfig] into the user-facing copy used in
/// composer placeholders and command titles. When [cfg] is null or has no
/// `noteLabel`, generic copy is returned ("Add a note", "Start a thread").
///
/// The connector populates `noteLabel` ("Comment" for Linear, "Message" for
/// Slack, "Reply" for Gmail) so the app's note/thread surfaces feel native to
/// the linked system.

/// Placeholder for the NewThreadPage body editor when the target is a Plot
/// thread (no connector). Driven by the (task, shared) flags.
///
/// - !task && !shared → "Add a note"
/// - task             → "Add a task"
/// - !task && shared  → "Start a chat"
String composerHintForNewThreadPlot({required bool task, required bool shared}) {
  if (task) return 'Add a task';
  if (shared) return 'Start a chat';
  return 'Add a note';
}

String composerHintForNote(LinkTypeConfig? cfg) {
  if (cfg?.replyPlaceholder != null && cfg!.replyPlaceholder!.isNotEmpty) {
    return cfg.replyPlaceholder!;
  }
  final noteLabel = cfg?.noteLabel?.toLowerCase();
  if (noteLabel != null && noteLabel.isNotEmpty) {
    return 'Add a $noteLabel';
  }
  return 'Add a note';
}

String composerHintForEditNote(LinkTypeConfig? cfg) {
  final note = cfg?.noteLabel;
  return note != null ? 'Edit ${note.toLowerCase()}' : 'Edit note';
}

String composerHintForNewThread(LinkTypeConfig? cfg, {String? connectorName}) {
  if (cfg == null) return 'Start a thread';
  if (cfg.composePlaceholder != null && cfg.composePlaceholder!.isNotEmpty) {
    return cfg.composePlaceholder!;
  }
  final label = cfg.label.toLowerCase();
  if (connectorName != null && connectorName.isNotEmpty) {
    return 'Create a new $connectorName $label';
  }
  return 'Create a new $label';
}

/// Send-button label on NewThreadPage when targeting a connector.
String composerVerbForNewThread(LinkTypeConfig? cfg) {
  return (cfg?.composeVerb?.isNotEmpty ?? false) ? cfg!.composeVerb! : 'Create';
}

/// Send-button label in the in-thread editor.
String composerVerbForNote(LinkTypeConfig? cfg) {
  return (cfg?.replyVerb?.isNotEmpty ?? false) ? cfg!.replyVerb! : 'Send';
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

import 'package:super_editor/super_editor.dart';

/// Attribution for editor mentions that are being composed (typed)
const editorMentionComposingAttribution = NamedAttribution('editorMentionComposing');

/// Attribution for completed editor mentions
class CommittedEditorMentionAttribution extends NamedAttribution {
  const CommittedEditorMentionAttribution({
    required this.priorityTwistId,
    required this.username,
  }) : super('editorMentionCommitted');

  final String priorityTwistId;
  final String username;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CommittedEditorMentionAttribution &&
          super == other &&
          priorityTwistId == other.priorityTwistId &&
          username == other.username);

  @override
  int get hashCode => Object.hash(super.hashCode, priorityTwistId, username);
}

/// A request to insert an editor mention at the current caret position
class InsertEditorMentionRequest implements EditRequest {
  const InsertEditorMentionRequest({
    required this.username,
  });

  final String username;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is InsertEditorMentionRequest && username == other.username);

  @override
  int get hashCode => username.hashCode;
}

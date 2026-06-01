import 'package:plot/store/store.dart' show CreateLinkUserAction, TwistInstance;
import 'package:plot/widget/connection_targets.dart' show CreateTarget;

/// A selectable connection on the compose surface. Either a real
/// [CreateTarget] (Slack channel, Linear team, …), one of the three Plot
/// thread variants (note / task / chat), or a [TwistInstance] (chat with a
/// twist — Plot AI, etc.).
sealed class ConnectionChoice {
  String get key;
  String get label;
  String? get logo;
  String? get logoDark;
  String get searchText;

  /// Returns the [CreateLinkUserAction] to attach to the draft, or null
  /// for the Plot-thread / twist choices (which use other state to track
  /// selection — twist selection lives in `thread.icon` via
  /// `_selectTwist`).
  CreateLinkUserAction? toUserAction();

  /// Plot thread variants. The underlying data model is the same — a
  /// regular Plot thread — but each variant signals a different default
  /// state to the compose page:
  ///
  /// - [plotNote]: no task tag, no contacts. Placeholder "Add a note".
  /// - [plotTask]: first note carries [Tag.todo]. Placeholder "Add a task".
  /// - [plotChat]: signals shared intent — placeholder "Start a chat" even
  ///   before the user has added a contact. Sticky once a contact has been
  ///   added (the chat label survives temporary contact removal mid-compose).
  static const PlotThreadChoice plotNote =
      PlotThreadChoice._(PlotThreadKind.note);
  static const PlotThreadChoice plotTask =
      PlotThreadChoice._(PlotThreadKind.task);
  static const PlotThreadChoice plotChat =
      PlotThreadChoice._(PlotThreadKind.chat);

  /// Default Plot variant when nothing else is known. Maps to [plotNote].
  static const PlotThreadChoice plotDefault = plotNote;

  /// Returns the Plot variant for the given [kind].
  static PlotThreadChoice plotForKind(PlotThreadKind kind) => switch (kind) {
        PlotThreadKind.note => plotNote,
        PlotThreadKind.task => plotTask,
        PlotThreadKind.chat => plotChat,
      };

  /// Wrap a real [CreateTarget] as a choice.
  factory ConnectionChoice.target(CreateTarget target) =
      TargetConnectionChoice;

  /// Wrap a [TwistInstance] as a choice. Only twists whose `threadType`
  /// is non-null should be wrapped — the picker filters before calling
  /// this constructor.
  factory ConnectionChoice.twist(
    TwistInstance twist, {
    required List<TwistInstance> allInstances,
    String? teamName,
  }) = TwistConnectionChoice;
}

/// Which Plot thread variant the user picked from the connection list.
enum PlotThreadKind { note, task, chat }

/// One of the three Plot thread variants. Selecting it clears any
/// [CreateLinkUserAction] on the draft and clears any selected twist;
/// the compose page applies the variant-specific defaults
/// (task tag, sticky-chat flag) after the choice is set.
class PlotThreadChoice implements ConnectionChoice {
  const PlotThreadChoice._(this.kind);

  final PlotThreadKind kind;

  @override
  String get key => switch (kind) {
        PlotThreadKind.note => 'plot:note',
        PlotThreadKind.task => 'plot:task',
        PlotThreadKind.chat => 'plot:chat',
      };

  @override
  String get label => switch (kind) {
        PlotThreadKind.note => 'Plot note',
        PlotThreadKind.task => 'Plot task',
        PlotThreadKind.chat => 'Plot chat',
      };

  @override
  String? get logo => null;

  @override
  String? get logoDark => null;

  @override
  String get searchText => label.toLowerCase();

  @override
  CreateLinkUserAction? toUserAction() => null;
}

/// A real [CreateTarget] wrapped as a [ConnectionChoice].
class TargetConnectionChoice implements ConnectionChoice {
  TargetConnectionChoice(this.target);

  final CreateTarget target;

  @override
  String get key => target.key;

  @override
  String get label => target.chipLabel;

  @override
  String? get logo => target.linkType.logo;

  @override
  String? get logoDark => target.linkType.logoDark;

  @override
  String get searchText => target.searchText;

  @override
  CreateLinkUserAction? toUserAction() => target.toUserAction();
}

/// A [TwistInstance] wrapped as a [ConnectionChoice]. Used for "chat with"
/// targets like Plot AI. Selection is applied via the parent page's
/// existing `_selectTwist` path (sets `thread.icon = 'twist:N'`); this
/// choice does not produce a `CreateLinkUserAction`.
class TwistConnectionChoice implements ConnectionChoice {
  TwistConnectionChoice(
    this.twist, {
    required this.allInstances,
    this.teamName,
  });

  final TwistInstance twist;
  final List<TwistInstance> allInstances;
  final String? teamName;

  String get _displayThreadType =>
      twist.threadType ?? '${twist.handle.isEmpty ? twist.name : twist.handle} chat';

  String get _scopeSuffix {
    if (twist.multipleInstances) return '';
    final hasSibling = allInstances.any(
      (other) =>
          other.id != twist.id &&
          other.twistId == twist.twistId &&
          other.archivedAt == null,
    );
    if (!hasSibling) return '';
    final scopeLabel = twist.teamId == null ? 'Personal' : (teamName ?? 'Team');
    return ' ($scopeLabel)';
  }

  @override
  String get key => 'twist:${twist.id}';

  @override
  String get label => '$_displayThreadType$_scopeSuffix';

  @override
  String? get logo => twist.logoUrl;

  @override
  String? get logoDark => twist.logoUrlDark;

  @override
  String get searchText =>
      '${_displayThreadType.toLowerCase()} ${(twist.handle.isEmpty ? twist.name : twist.handle).toLowerCase()}';

  @override
  CreateLinkUserAction? toUserAction() => null;
}

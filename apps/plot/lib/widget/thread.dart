import 'dart:async';

// OverflowBoxFit is part of OverflowBox's public API but flutter/widgets.dart
// doesn't re-export the enum — this narrow `show` is the only way to name it.
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/services.dart';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:prism_flutter/prism_flutter.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/logo_cache.dart';
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/widget/thread_assignee.dart';
import 'package:plot/widget/thread_swipe_commands.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/state/priority.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/util/channel_breadcrumb.dart';
import 'package:plot/widget/status_icon_button.dart';
import 'package:plot/util/hooks.dart';
import 'package:plot/util/shortcut.dart';
import 'package:url_launcher/url_launcher.dart';

/// Whether a thread row should reserve the participant-name header slot.
///
/// The slot is reserved on the *stable* contact-id set while the Actor cache is
/// still warming ([actorsLoaded] is false), so it doesn't shift as names settle
/// in. Once loading completes it is kept only if a name actually resolved
/// ([hasResolvedLabel]) — a thread whose only "contact" is an unresolvable id
/// (e.g. a twist instance that isn't synced to this client) collapses the slot
/// rather than leaving a permanent empty header band. Channel threads never use
/// this slot (they show the channel breadcrumb instead).
bool reserveContactsLabel({
  required bool isChannelThread,
  required bool hasContactIds,
  required bool actorsLoaded,
  required bool hasResolvedLabel,
}) => !isChannelThread && hasContactIds && (!actorsLoaded || hasResolvedLabel);

/// The right-edge inset (px) to append after the trailing command cluster so
/// its trailing-most *visible* element lines up with the header timestamp.
///
/// The cluster is overlaid via a [Positioned] whose negative offset is tuned
/// for a ghost icon button: the button box extends past the content edge by its
/// internal icon padding, landing the glyph (inset by that padding) right at the
/// content edge — the same edge the header timestamp sits at. A trailing item
/// that is *not* a padded ghost button needs compensation so it doesn't
/// overshoot to the panel edge:
///   - The RSVP chip is a bare pill (its visible edge is its box edge).
///   - A *read-only* assignee avatar is rendered bare (ThreadAssignee returns
///     the AvatarGroup directly, with no button wrapper or padding).
/// Both are pulled in by one [ghostIconPadding].
///
/// A *writable* assignee avatar is itself a padded ghost button (ThreadAssignee
/// wraps it in `FButton.icon` with the same icon padding), so it already hugs
/// the edge exactly like a sibling icon button — insetting it again double-pads
/// it ~one icon-padding inboard of the timestamp. The persistent cluster ends
/// with `… · rsvp · assignee`, so the assignee is the trailing-most item
/// whenever it is present, and the RSVP chip only when there is no assignee.
double trailingClusterInset({
  required bool hasRsvpChip,
  required bool hasAssignee,
  required bool assigneeIsReadOnly,
  required double ghostIconPadding,
}) {
  final trailingIsBareAvatar = hasAssignee && assigneeIsReadOnly;
  final trailingIsBareChip = !hasAssignee && hasRsvpChip;
  return (trailingIsBareAvatar || trailingIsBareChip) ? ghostIconPadding : 0.0;
}

/// How a plain row tap should be interpreted (see [_rowClickIntent]).
enum _RowClickIntent { open, toggle, range }

class ThreadWidget extends StatefulWidget {
  const ThreadWidget({
    required this.activity,
    this.context,
    this.selected = false,
    this.highlighted = false,
    this.now = false,
    this.isNext = false,
    this.isAssociated = false,
    this.isOutsidePriority = false,
    this.showSubPriority = false,
    this.isSearch = false,
    this.showEventTiming = false,
    this.bump = true,
    this.focusNode,
    this.onHover,
    this.reorderableIndex,
    this.onSwipeExit,
    this.onDesktopFinish,
    this.onMobileFinish,
    this.onActivate,
    this.multiSelected = false,
    this.multiSelectMode = false,
    super.key,
  });

  final Thread activity;
  final Priority? context;
  final bool highlighted;
  final bool selected;
  final bool now;
  final bool isNext;
  final bool isAssociated;

  /// Whether this thread is from a priority outside the current context.
  /// Outside-priority link-scheduled events are dimmed in the UI.
  final bool isOutsidePriority;
  final bool showSubPriority;

  /// Whether this row is part of a global search result list. Search spans
  /// every focus, so each result must carry its focus label — including
  /// threads filed in the current focus and in the Inbox (root) — instead of
  /// suppressing the label when the thread's focus matches [context].
  final bool isSearch;
  final bool showEventTiming;
  final bool bump;
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;
  final int? reorderableIndex;
  final Future<void> Function(Command command)? onSwipeExit;

  /// Called before a finish command runs on desktop (icon click path).
  /// Should trigger the fade+collapse removal animation.
  final Future<void> Function()? onDesktopFinish;

  /// Called before a finish command runs on mobile (toggle tap path).
  /// Should trigger collapse-only removal animation.
  final Future<void> Function()? onMobileFinish;

  /// Overrides the row's tap-to-open behaviour. When non-null, tapping the
  /// row runs this callback instead of the default [ChangeCurrentThread]
  /// navigation. Used by the Search tab to open results on its own
  /// PriorityRoute→ThreadRoute stack rather than the current priority's.
  /// When null, the default in-place [ChangeCurrentThread] navigation runs.
  final VoidCallback? onActivate;

  /// True when this row is part of the current multi-selection. Drives the
  /// opened-thread background tint and the checked leading checkbox.
  final bool multiSelected;

  /// True when a multi-selection is in progress anywhere in the feed. Every row
  /// swaps its leading to-do circle for a selection checkbox and suppresses
  /// hover affordances (the move-on-hover logo, the trailing command cluster).
  final bool multiSelectMode;

  @override
  State<ThreadWidget> createState() => _ThreadWidgetState();
}

class _ThreadWidgetState extends State<ThreadWidget> {
  bool _leadingHovered = false;
  bool _rowHovered = false;
  BlockDragController? _dragController;

  /// True for [_finishConfirmDuration] after this thread transitions
  /// todo → done, so the leading icon flashes a filled `circleCheck` to
  /// confirm the action before reverting to its resting (inactive) state.
  /// Mirrors the feed's post-unfocus move grace window length.
  bool _finishConfirm = false;
  Timer? _finishConfirmTimer;
  static const _finishConfirmDuration = Duration(milliseconds: 1500);

  /// Links for this thread, watched per-row so the header can show a channel
  /// breadcrumb when the primary link is channel-sharing. The breadcrumb
  /// decision feeds [_buildListTile]'s `hasTopLabel`/`labelOffset` (which keep
  /// the leading checkbox aligned), so it must be resolved synchronously in
  /// build — hence a State subscription rather than a descendant stream.
  StreamSubscription<List<Link>>? _linksSub;
  List<Link> _links = const [];

  /// Resolved actors for the "other contacts" on the thread (see
  /// [_otherContactIds]), keyed for the header name label. The *set* of ids is
  /// stable thread-row data; only the resolved [Actor] objects (for their
  /// names) warm in asynchronously here, filling the already-reserved label
  /// slot without shifting layout.
  Map<Uuid, Actor> _otherActors = const {};
  String? _otherContactsKey;

  /// True once [_loadOtherActors] has finished resolving the current id set.
  /// While false the name slot is reserved on the stable id set (so it doesn't
  /// shift as names warm in); once true, the slot is only kept if at least one
  /// name actually resolved — otherwise it collapses rather than leaving a
  /// permanent empty header band (e.g. a thread whose only contact is a twist
  /// instance that isn't synced to this client).
  bool _otherActorsLoaded = false;

  /// True while a block-level drag is in progress anywhere in the agenda.
  /// Threads are not drop targets for block drags — suppressing the hover
  /// effect prevents the row from looking like one.
  bool get _isBlockDragging => _dragController?.isDragging ?? false;

  @override
  void initState() {
    super.initState();
    // Seed from the synchronous links cache so the channel breadcrumb header
    // is present on first paint instead of popping in a frame or two later
    // (jank when switching focuses). The subscription below keeps it live.
    _links = Link.cachedForThread(activity.id) ?? const [];
    _subscribeLinks();
    _loadOtherActors();
  }

  void _subscribeLinks() {
    _linksSub?.cancel();
    _linksSub = Link.watchForThread(activity.id).listen((links) {
      if (!mounted) return;
      setState(() => _links = links);
    });
  }

  /// Warm [_otherActors] from the Actor store so the header name label can
  /// render names. Only the names settle in — the *set* of ids (and therefore
  /// every layout decision) is already known synchronously from the thread row.
  void _loadOtherActors() {
    final ids = _otherContactIds();
    final key = ids.map((u) => u.toString()).join('|');
    if (key == _otherContactsKey) return;
    _otherContactsKey = key;
    _otherActorsLoaded = false;
    () async {
      final resolved = <Uuid, Actor>{};
      for (final id in ids) {
        try {
          resolved[id] = await Actor.getOne(ActorId.fromUuid(id));
        } catch (_) {
          // Skip contacts whose actors can't be resolved.
        }
      }
      if (!mounted) return;
      setState(() {
        _otherActors = resolved;
        _otherActorsLoaded = true;
      });
    }();
  }

  @override
  void didUpdateWidget(covariant ThreadWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity.id != widget.activity.id) {
      // Re-seed from cache rather than blanking, so a recycled row keeps its
      // channel breadcrumb on the first frame after the id changes.
      _links = Link.cachedForThread(widget.activity.id) ?? const [];
      _otherActors = const {};
      _otherContactsKey = null;
      _subscribeLinks();
      // Recycled to a different thread — abandon any in-flight finish flash.
      _finishConfirmTimer?.cancel();
      _finishConfirm = false;
    } else if (oldWidget.activity.todo && !widget.activity.todo) {
      // Same thread just transitioned todo → done (here or from the open
      // thread's Done button): flash circleCheck for a moment to confirm.
      _finishConfirmTimer?.cancel();
      _finishConfirm = true;
      _finishConfirmTimer = Timer(_finishConfirmDuration, () {
        if (!mounted) return;
        setState(() => _finishConfirm = false);
      });
    } else if (widget.activity.todo && _finishConfirm) {
      // Re-marked To do during the flash — drop the confirmation immediately.
      _finishConfirmTimer?.cancel();
      _finishConfirm = false;
    }
    _loadOtherActors();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newController = BlockDragScope.maybeOf(context);
    if (newController != _dragController) {
      _dragController?.removeListener(_onDragChanged);
      _dragController = newController;
      _dragController?.addListener(_onDragChanged);
    }
  }

  @override
  void dispose() {
    _linksSub?.cancel();
    _finishConfirmTimer?.cancel();
    _dragController?.removeListener(_onDragChanged);
    super.dispose();
  }

  /// The channel breadcrumb for this thread, or null when the primary
  /// (primary canonical) link is not channel-sharing — the same primary link
  /// that [Thread.resolveSharingModel] keys on (see [Thread.primaryLink]).
  /// Resolved from the in-memory [TwistInstance]/[Channel] caches, falling
  /// back to whichever part resolves.
  String? _channelLabel() {
    if (Thread.resolveSharingModel(_links) != SharingModel.channel) return null;
    final primary = Thread.primaryLink(_links);
    if (primary == null) return null;
    final ptId = primary.createdBy;
    if (ptId == null) return null;
    // Prefer the per-connection account label (e.g. "Acme Co") over the
    // connector name (e.g. "Slack"); fall back to the name when a connection
    // has no account label.
    final instance = TwistInstance.fromCache(ptId);
    final workspace = (instance?.accountLabel?.isNotEmpty ?? false)
        ? instance!.accountLabel
        : instance?.name;
    final channelId = primary.channelId;
    final channel = channelId != null
        ? Channel.findByChannel(ptId, channelId)?.title
        : null;
    return formatChannelBreadcrumb(workspace: workspace, channel: channel);
  }

  /// True when this thread's sharing is scoped to an external channel. Channel
  /// threads show the [_channelLabel] breadcrumb instead of contact names.
  /// Empty links resolve to [SharingModel.thread], so this is false (the stable
  /// default) until links load.
  bool get _isChannelThread =>
      Thread.resolveSharingModel(_links) == SharingModel.channel;

  /// The "other contacts" on the thread, in thread order: every contact except
  /// the current user, dropped contacts, and connection-source twists (Google
  /// Calendar, Slack, …). Non-connection twists (e.g. "Plot AI") are kept. The
  /// thread's author (if not the current user) is promoted to the front.
  ///
  /// Derived purely from the thread row plus startup-critical caches
  /// (current-user actors, twist instances), so the result — and whether the
  /// header name label is reserved — is stable from first paint.
  List<Uuid> _otherContactIds() {
    final self = Actor.getCurrentUserActorIds().map((a) => a.toUuid()).toSet();
    final dropped = activity.droppedContacts.toSet();
    final out = <Uuid>[];
    final seen = <Uuid>{};
    for (final id in activity.contacts) {
      if (self.contains(id)) continue;
      if (dropped.contains(id)) continue;
      // Connection-source twist (a connection like Google Calendar). Plain
      // twists (isSource == false, e.g. Plot AI) are kept as participants.
      if (TwistInstance.fromCache(id)?.isSource ?? false) continue;
      if (seen.add(id)) out.add(id);
    }

    // Promote the thread's author to the front so the person who started the
    // thread leads the name list. Skip when the current user is the author —
    // own threads keep their natural order (self is already excluded from
    // `out` above) — and when the author isn't a current participant or is
    // already first, both of which no-op below. `authorId` is null on older /
    // un-backfilled threads, leaving the order untouched.
    final authorId = activity.authorId?.toUuid();
    if (authorId != null && !self.contains(authorId)) {
      final index = out.indexOf(authorId);
      if (index > 0) {
        out.removeAt(index);
        out.insert(0, authorId);
      }
    }
    return out;
  }

  /// Comma-joined participant names for the header, shown in the same slot as
  /// [_channelLabel] for non-channel threads. Returns null for channel threads
  /// (they use the breadcrumb) and when there are no other contacts. Names
  /// settle in as [_otherActors] warms; whether the slot is reserved is decided
  /// synchronously by [_otherContactIds] so it never shifts layout.
  String? _contactsLabel() {
    if (_isChannelThread) return null;
    final ids = _otherContactIds();
    if (ids.isEmpty) return null;

    final names = <String>[];
    for (final id in ids) {
      final actor = _otherActors[id] ?? Actor.fromCache(ActorId.fromUuid(id));
      if (actor != null) names.add(actor.nameOrEmail);
    }
    if (names.isEmpty) return null;
    return names.join(', ');
  }

  void _onDragChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Thread get activity => widget.activity;
  Priority? get priorityContext => widget.context;
  bool get highlighted => widget.highlighted;
  bool get selected => widget.selected;
  bool get now => widget.now;
  bool get isNext => widget.isNext;
  bool get showSubPriority => widget.showSubPriority;
  bool get isSearch => widget.isSearch;
  bool get showEventTiming => widget.showEventTiming;
  bool get bump => widget.bump;
  bool get multiSelected => widget.multiSelected;
  bool get multiSelectMode => widget.multiSelectMode;
  FocusNode? get focusNode => widget.focusNode;
  void Function(bool hovered)? get onHover => widget.onHover;
  int? get reorderableIndex => widget.reorderableIndex;

  /// Resolves a plain row tap to its intent based on held modifier keys and
  /// platform. Multi-select needs a physical keyboard, so touch always opens.
  /// Toggle modifier is Cmd on macOS, Ctrl elsewhere; Shift selects a range.
  _RowClickIntent _rowClickIntent() {
    if (!hasPhysicalKeyboard()) return _RowClickIntent.open;
    final keys = HardwareKeyboard.instance;
    if (keys.isShiftPressed) return _RowClickIntent.range;
    final togglePressed = defaultTargetPlatform == TargetPlatform.macOS
        ? keys.isMetaPressed
        : keys.isControlPressed;
    if (togglePressed) return _RowClickIntent.toggle;
    return _RowClickIntent.open;
  }

  void _handleRowTap(BuildContext context) {
    switch (_rowClickIntent()) {
      case _RowClickIntent.toggle:
        context.run(ToggleThreadSelection(activity));
      case _RowClickIntent.range:
        context.run(SelectThreadRange(activity));
      case _RowClickIntent.open:
        // Opens the thread; ChangeCurrentThread also exits any multi-select.
        context.run(ChangeCurrentThread(activity));
    }
  }

  // Swipe actions. Right = act on it (Done short, engage long); left = file it
  // (Move short, menu long). The full per-state mapping — including the Done
  // list, where right re-engages instead of finishing — lives in
  // [resolveThreadSwipeCommands].
  ThreadSwipeCommands _swipeCommands() => resolveThreadSwipeCommands(
    activity,
    isOutsidePriority: widget.isOutsidePriority,
    bump: bump,
    // Link schedule instances stay visible after finish, so skip the removal
    // animation. Otherwise, when a swipe-exit animation is wired, hand the
    // removal to it via an empty callback so FinishThread doesn't also remove
    // the row.
    finishOnBeforeRun: activity.isLinkScheduleInstance
        ? null
        : widget.onSwipeExit != null
        ? (_) async {}
        : null,
  );

  Widget _buildListTile(BuildContext buildContext, bool isTouchDevice) {
    // In a focus feed the label is shown only for threads filed elsewhere
    // (it would be redundant on threads already in the current focus). Search
    // is global, so every result carries its focus label — including threads
    // in the current focus and the Inbox (FocusLabel renders root as "Inbox").
    final hasSubPriorityLabel =
        showSubPriority &&
        (isSearch ||
            (priorityContext != null &&
                activity.priority.id != priorityContext!.id));

    final hasEventTime =
        activity.at?.start != null &&
        !activity.at!.start!.toTimeOfDay().isMidnight;

    final isTodoBase = activity.todo && !activity.isLinkScheduleInstance;

    // Channel breadcrumb (e.g. "Acme Co › #general") shown in all lists when
    // the thread's primary link is channel-sharing. The focus segment below is
    // still feed-only (gated by showSubPriority).
    final channelLabel = _channelLabel();
    final hasChannelLabel = channelLabel != null;

    // Participant names in the header. While the Actor cache is still warming
    // (`!_otherActorsLoaded`), the slot is reserved on the *stable* id set (not
    // the resolved names) so `hasTopLabel`/`labelOffset` don't shift as names
    // settle in. Once loading completes, the slot is only kept if a name
    // actually resolved — a thread whose only "contact" is an unresolvable id
    // (e.g. a twist instance not synced to this client) collapses the slot
    // instead of leaving a permanent empty header band.
    final contactsLabel = _isChannelThread ? null : _contactsLabel();
    final hasContactsLabel = reserveContactsLabel(
      isChannelThread: _isChannelThread,
      hasContactIds: _otherContactIds().isNotEmpty,
      actorsLoaded: _otherActorsLoaded,
      hasResolvedLabel: contactsLabel != null,
    );

    final hasBodyLabel =
        hasChannelLabel || hasContactsLabel || hasSubPriorityLabel;

    final scheduleDate = () {
      // User-scheduled todos only show the label when a linked event provides
      // the date (e.g. a calendar event); plain todos hide it.
      if (isTodoBase && !activity.hasLinkSchedule) return null;
      // Events with their own start time never show a schedule label here;
      // the agenda's AgendaTile carries the time and the activity feed
      // shows it via the priority-hover row below.
      if (!isTodoBase && hasEventTime) return null;
      if (activity.recurring) {
        final nextDate = activity.nextOccurrence(
          CustomBoundedDateRange(Date.today(), Date.today().addDays(365)),
        );
        if (nextDate != null) {
          final time =
              activity.at?.start?.toTimeOfDay() ??
              const TimeOfDay(hour: 0, minute: 0);
          return nextDate.toDateTime(time: time);
        }
        return activity.at?.start;
      }
      return activity.at?.start;
    }();

    final hasScheduleLabel = scheduleDate != null;
    final hasTopLabel = hasBodyLabel || hasScheduleLabel;

    // The header band is always shown now — it carries the most-recent-note
    // relative time at its trailing end even on otherwise-bare private threads
    // — so always reserve its rendered height and push leading/trailing down
    // by the same amount, keeping them vertically centred with the title.
    final labelOffset = (TextPainter(
      text: TextSpan(
        text: 'A',
        style: TextStyle(
          fontSize: buildContext.theme.typography.xs.fontSize,
          height: 1,
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout()).height;

    // Relative time of the most recent note (matches the note footer, e.g.
    // "5 minutes ago"), shown right-aligned in the header. The word "ago" is
    // dropped on narrow single-panel layouts to conserve horizontal space.
    final relativeTime = activity.contentTimestamp.toTimeAgo(
      suffix: buildContext.isMultiPanel,
    );

    final threadColor = buildContext.colour.colours.fromTheme(
      activity.priority.displayColor,
    );
    final selectedBg = buildContext.colour.colours.backgroundFromTheme(
      activity.priority.displayColor,
    );
    // Multi-selected rows get the same background as the open thread (the open
    // thread additionally keeps its selection ring, drawn by the separator).
    final showSelected = selected || multiSelected;

    final listTile = ListTile(
      // When [onActivate] is provided (e.g. Search results), the row's tap
      // must run that callback INSTEAD of the default ChangeCurrentThread.
      // Pass no command so the command path can't fire ChangeCurrentThread,
      // and route the tap straight to onActivate.
      command: widget.onActivate != null
          ? null
          : CommandWrapper(ChangeCurrentThread(activity), icon: Value(null)),
      // Bypass ListTile's run() spinner tracking. The command returns
      // CommandDone immediately (navigation is fire-and-forget), but routing
      // it through context.run directly keeps the spinner machinery out of
      // the hot tap path entirely. Modifier-clicks (Cmd/Ctrl/Shift) are routed
      // to the selection commands by [_handleRowTap] instead of opening.
      onTap: widget.onActivate ?? () => _handleRowTap(buildContext),
      // Menu opens via long-left swipe on touch (see Swipeable wrapper
      // below) and via right-click on desktop (see ContextMenu wrapper
      // below). Long-press is reserved for starting a reorder drag.
      longPressCommand: null,
      crossAxisAlignment: CrossAxisAlignment.start,
      title: activity.displayTitle,
      subtitle: activity.displayPreview,
      padding: EdgeInsets.only(
        right: buildContext.isMultiPanel
            ? buildContext.theme.spacing.lg
            : buildContext.theme.buttonStyles.ghost.md.iconContentStyle.padding
                  .resolve(TextDirection.ltr)
                  .right,
      ),
      highlightColor: buildContext.colour.editableBackground,
      selectedColor: selectedBg,
      // While a block drag is in progress, threads are not drop targets —
      // suppress the bg highlight so the row doesn't read as one.
      noHoverHighlight: _isBlockDragging,
      leadingBuilder: (rawHovered, hasFocus) {
        final isHovered = _isBlockDragging ? false : rawHovered;
        final leadingHovered = _isBlockDragging ? false : _leadingHovered;
        final bool isTodo = activity.todo;
        // Brief post-finish confirmation: just after todo → done, flash a
        // filled circleCheck before the icon reverts to its inactive resting
        // state (see [_finishConfirm]).
        final bool confirmingFinish = _finishConfirm && !isTodo;

        // Leading button: unified-feed state icon.
        //   - !active resting: nothing visible.
        //   - !active hovered: `circlePlus` with "To do" tooltip; tap sets
        //                      active=true (lands in Doing).
        //   - active resting:  `circle`.
        //   - active hovered (leading button only): `circleCheck` with "Done"
        //                      tooltip; tap clears active and marks read
        //                      (lands in Activity).
        //   - just finished:   `circleCheck` flashed for ~1.5s to confirm.
        void longPress() => buildContext.run(PickScheduleThread(activity));

        final Command leadingCommand;
        if (!isTodo) {
          leadingCommand = ToggleThreadActive(activity);
        } else {
          leadingCommand = FinishThread(
            activity,
            bump: bump,
            // Link schedule instances must stay visible after finish (only the
            // base todo duplicate is removed), so skip the removal animation.
            onBeforeRun: activity.isLinkScheduleInstance
                ? null
                : widget.onMobileFinish != null
                ? (_) => widget.onMobileFinish!()
                : widget.onDesktopFinish != null
                ? (_) => widget.onDesktopFinish!()
                : null,
          );
        }

        final iconBaseSize = buildContext.theme.iconSizes.base;
        final leadingPad = buildContext.isMultiPanel
            ? buildContext.theme.spacing.lg
            : buildContext.theme.buttonStyles.ghost.md.iconContentStyle.padding
                  .resolve(TextDirection.ltr)
                  .right;
        final leadingW = iconBaseSize + leadingPad * 2;
        final spacing = buildContext.theme.spacing;
        // Touch ghost buttons carry a large (14px) icon padding so the circle
        // and hover commands clear the ~44px touch-target minimum. Pinning the
        // title row to that height (as desktop does) would leave the 16px title
        // floating with ~14px of dead space above and below it. The whole row
        // is the tap-to-open target, so on touch we size the title row to its
        // text instead (iconBase + `sm`*2, ≈ the desktop row height) and let the
        // circle/commands overflow their still-tappable bounds. Desktop keeps
        // the ghost-derived height unchanged.
        final ghostPadV = buildContext
            .theme
            .buttonStyles
            .ghost
            .md
            .iconContentStyle
            .padding
            .resolve(TextDirection.ltr)
            .vertical;
        final mainRowHeight =
            iconBaseSize + (isMobilePlatform() ? spacing.sm * 2 : ghostPadV);

        // Multi-select mode: the leading slot is a selection checkbox. Tapping
        // it toggles this thread in/out of the selection (it never opens the
        // thread). Hover affordances are suppressed in this mode.
        if (multiSelectMode) {
          return SizedBox(
            width: leadingW,
            child: Padding(
              padding: EdgeInsets.only(
                top: spacing.sm + labelOffset,
                bottom: spacing.sm,
              ),
              child: SizedBox(
                height: mainRowHeight,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => buildContext.run(ToggleThreadSelection(activity)),
                  child: Center(
                    child: Icon(
                      multiSelected
                          ? FontAwesomeIcons.squareCheck
                          : FontAwesomeIcons.square,
                      size: iconBaseSize,
                      color: multiSelected
                          ? threadColor
                          : buildContext.colour.muted,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        final Widget todoIcon;
        final String leadingTitle = !isTodo ? 'To do' : 'Done';
        final iconHoverColor = leadingHovered
            ? buildContext.colour.foreground
            : buildContext.colour.muted;
        if (confirmingFinish) {
          // Just finished: flash a filled circleCheck (forced visible) for
          // ~1.5s. Tapping it re-marks To do (leadingCommand is
          // ToggleThreadActive while !isTodo).
          todoIcon = Button.icon(
            _ThreadLeadingCommand(
              leadingCommand,
              outlineIcon: FontAwesomeIcons.check,
              iconHoverColor: threadColor,
              hoverIcon: Value(FontAwesomeIcons.check),
              title: leadingTitle,
            ),
            selected: true,
            selectedColor: threadColor,
            forceHover: true,
            onLongPress: longPress,
          );
        } else if (!isTodo) {
          // Inactive: hidden at rest, circlePlus on hover.
          todoIcon = Button.icon(
            _ThreadLeadingCommand(
              leadingCommand,
              outlineIcon: FontAwesomeIcons.circlePlus,
              showEmpty: !activity.unread,
              dotColor: activity.unread
                  ? buildContext.colour.accent.withValues(alpha: 0.7)
                  : null,
              iconHoverColor: iconHoverColor,
              hoverIcon: Value(FontAwesomeIcons.circlePlus),
              title: leadingTitle,
            ),
            forceHover: isHovered,
            onLongPress: longPress,
          );
        } else {
          // Active: circle at rest; circleCheck only when hovering the leading
          // button itself (not anywhere on the row). Unread overlays a
          // centered dot on the circle.
          todoIcon = Button.icon(
            _ThreadLeadingCommand(
              leadingCommand,
              outlineIcon: FontAwesomeIcons.circle,
              dotColor: activity.unread
                  ? buildContext.colour.accent.withValues(alpha: 0.7)
                  : null,
              dotOverOutline: true,
              iconHoverColor: iconHoverColor,
              hoverIcon: Value(FontAwesomeIcons.circleCheck),
              title: leadingTitle,
            ),
            selected: true,
            selectedColor: threadColor,
            forceHover: leadingHovered,
            onLongPress: longPress,
          );
        }

        return SizedBox(
          width: leadingW,
          child: Padding(
            // Mirror the body's vertical rhythm exactly: `sm` top, the
            // `labelOffset` label slot, the `mainRowHeight` title box, then `sm`
            // bottom. That makes the circle's box start at the same Y as the
            // title box, so the centred circle lines up with the centred title
            // on both labelled and no-label rows.
            padding: EdgeInsets.only(
              top: spacing.sm + labelOffset,
              bottom: spacing.sm,
            ),
            child: SizedBox(
              height: mainRowHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Full-area tap/hover target
                  Positioned.fill(
                    child: MouseRegion(
                      onEnter: (_) => setState(() => _leadingHovered = true),
                      onExit: (_) => setState(() => _leadingHovered = false),
                      child: FTooltip(
                        tipBuilder: (context, controller) => Text(leadingTitle),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => buildContext.run(leadingCommand),
                          onLongPress: longPress,
                        ),
                      ),
                    ),
                  ),
                  // Centered icon (visual only). On touch the ghost button is
                  // intrinsically taller (44px tap padding) than mainRowHeight;
                  // a plain Center would CLAMP it to the box (Clip.none affects
                  // painting, not layout), top-anchoring the glyph ~8px below
                  // the row centre. OverflowBox lets it keep its intrinsic
                  // height and centres it on the box, overflowing evenly top
                  // and bottom. Its tap target is the row-sized
                  // Positioned.fill above, so layout overflow is harmless.
                  Center(
                    child: IgnorePointer(
                      child: OverflowBox(
                        maxHeight: double.infinity,
                        child: todoIcon,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      bodyBuilder: (buildCtx, rawHighlighted) {
        // While a block drag is in progress, treat the thread as not
        // highlighted so it doesn't render edit affordances or the
        // ThreadCommands row that would make it look like a drop target.
        // Suppress all hover affordances (move-on-hover logo, the trailing
        // command cluster, hover background) while a block drag or a
        // multi-select is in progress.
        final isHighlighted =
            (_isBlockDragging || multiSelectMode) ? false : rawHighlighted;
        // State-dependent colors – only selection unmutes foreground;
        // hover should not change any foreground colors.
        final headerFg = showSelected ? threadColor : null;

        // Opaque composited bg for ThreadCommands gradient
        final compositedBg = showSelected
            ? selectedBg
            : isHighlighted
            ? buildContext.colour.editableBackground
            : buildContext.colour.background;

        // On touch, size the title row to its text rather than the inflated
        // ghost-button height (see `mainRowHeight` in the leading builder), so
        // the title doesn't float in dead space. Desktop is unchanged. The
        // outer `sm` wrapper (which gives the contact-name header row above its
        // breathing room) stays as-is.
        final ghostPadV = buildContext
            .theme
            .buttonStyles
            .ghost
            .md
            .iconContentStyle
            .padding
            .resolve(TextDirection.ltr)
            .vertical;
        final mainRowHeight =
            buildContext.theme.iconSizes.base +
            (isMobilePlatform()
                ? buildContext.theme.spacing.sm * 2
                : ghostPadV);
        return Padding(
          padding: EdgeInsets.only(
            top: buildContext.theme.spacing.sm,
            bottom: buildContext.theme.spacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header band. Always shown (even bare private threads carry the
              // trailing relative time). Reserve exactly `labelOffset` — the
              // same amount the leading column is pushed down by (see its
              // `top: sm + labelOffset`). The label's intrinsic Figtree height
              // and the leading's font-agnostic TextPainter estimate drift
              // apart on touch, which left the title row and the leading circle
              // starting at slightly different Ys (circle sat low on labelled
              // rows). Pinning the slot to `labelOffset` keeps them aligned by
              // construction. The label content is shorter than the slot, so
              // nothing clips.
              SizedBox(
                height: labelOffset,
                child: DefaultTextStyle(
                  style: TextStyle(
                    color:
                        headerFg ?? buildContext.theme.colors.mutedForeground,
                    fontSize: buildContext.theme.typography.xs.fontSize,
                    height: 1,
                  ),
                  child: Builder(
                    builder: (context) {
                      // Left-side header segments in order: focus · channel ·
                      // contacts/groups · schedule. The focus is a purely
                      // static label (no tap-to-move affordance). Each present
                      // segment is joined to the previous with a dot separator.
                      final segments = <Widget>[
                        if (hasSubPriorityLabel)
                          Flexible(
                            child: FocusLabel(
                              priority: activity.priority,
                              color: headerFg,
                              fontSize: context.theme.typography.xs.fontSize,
                              height: 1,
                              muted: headerFg == null,
                            ),
                          ),
                        if (hasChannelLabel)
                          Flexible(
                            child: Text(
                              channelLabel,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        if (contactsLabel != null)
                          Flexible(
                            child: Text(
                              contactsLabel,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        if (scheduleDate != null)
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: formatRelativeSchedule(
                                    scheduleDate,
                                    context,
                                  ),
                                ),
                                if (activity.duration != null &&
                                    activity.duration!.inSeconds > 0)
                                  TextSpan(
                                    text: ' · ${activity.duration!.format()}',
                                  ),
                              ],
                            ),
                          ),
                      ];
                      final joined = <Widget>[
                        for (var i = 0; i < segments.length; i++) ...[
                          if (i > 0) const Text(' · '),
                          segments[i],
                        ],
                      ];
                      // Left segments take the available width (ellipsizing
                      // when long); the relative time keeps its intrinsic width
                      // pinned to the trailing end. `hasTopLabel` guards the
                      // empty case so a bare thread shows only the time.
                      return Row(
                        children: [
                          Expanded(
                            child: hasTopLabel
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: joined,
                                  )
                                : const SizedBox.shrink(),
                          ),
                          Padding(
                            padding: EdgeInsets.only(
                              left: context.theme.spacing.sm,
                            ),
                            child: Text(
                              relativeTime,
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              // SizedBox + Stack keeps the title row height stable
              // regardless of whether ThreadCommands buttons are visible.
              // On desktop the height matches FButton.icon (icon size +
              // icon-content padding) so it equals the leading button area and
              // the hover ThreadCommands buttons stay hit-testable (RenderBox
              // rejects hits outside its size). On touch the ghost padding is
              // large (44px tap targets) and would leave the title floating, so
              // we size to the text instead (`mainRowHeight`); the
              // circle/commands overflow but remain tappable via their
              // row-sized fill, and touch uses swipes for the command actions.
              SizedBox(
                height: mainRowHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: isHighlighted && !widget.isOutsidePriority
                                ? _MoveHoverIcon(activity: activity)
                                : _ThreadLogo(activity: activity),
                          ),
                          SizedBox(width: buildContext.theme.spacing.md),
                          Expanded(
                            child: Text.rich(
                              overflow: TextOverflow.ellipsis,
                              style: buildContext.theme.typography.md.copyWith(
                                color: buildContext.colour.foreground,
                                // forui's `md` carries height:1.5. With the
                                // default proportional leading, that ascent-
                                // heavy extra space sinks the glyph ~0.15·
                                // fontSize below its line-box centre — invisible
                                // at desktop's 15px but ~2px at touch's 16px,
                                // which left titles (and the row) sitting low.
                                // Centre the glyph in its line box on touch so
                                // it lines up with the logo and the leading
                                // circle; desktop keeps forui's default (right
                                // there).
                                leadingDistribution: isMobilePlatform()
                                    ? TextLeadingDistribution.even
                                    : null,
                              ),
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: activity.displayTitle,
                                    style: now
                                        ? TextStyle(
                                            color: buildContext.colour.colours
                                                .fromTheme(
                                                  activity
                                                      .priority
                                                      .displayColor,
                                                ),
                                          )
                                        : showSelected
                                        ? TextStyle(
                                            color:
                                                buildContext.colour.foreground,
                                          )
                                        : null,
                                  ),
                                  if (activity.displayPreview != null &&
                                      activity.displayPreview!.isNotEmpty &&
                                      activity.displayPreview !=
                                          activity.displayTitle)
                                    TextSpan(
                                      text: '  ${activity.displayPreview}',
                                      style: TextStyle(
                                        color: buildContext.colour.muted,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // ThreadCommands is overlaid via Positioned so it
                    // doesn't affect title row height. A gradient fade
                    // and solid background match the ListTile's
                    // effective background so the title text is cleanly
                    // truncated rather than bleeding through the buttons.
                    Positioned(
                      // Push the trailing row right by exactly the ghost
                      // button's internal icon padding, so the visible glyph /
                      // avatar lands at the ListTile's content edge — the same
                      // right edge the header timestamp (and the agenda's
                      // block-header durations, also `spacing.lg` in) sit at.
                      // No extra nudge beyond the icon padding: the status
                      // circle / check and the assignee avatar fill their icon
                      // box, so any additional offset visibly overshoots the
                      // timestamp's right edge.
                      right: -buildContext
                          .theme
                          .buttonStyles
                          .ghost
                          .md
                          .iconContentStyle
                          .padding
                          .resolve(TextDirection.ltr)
                          .right,
                      top: 0,
                      bottom: 0,
                      child: Builder(
                        builder: (context) {
                          final tileBg = compositedBg;
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 24,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      tileBg.withValues(alpha: 0),
                                      tileBg,
                                    ],
                                  ),
                                ),
                              ),
                              ColoredBox(
                                color: tileBg,
                                // On touch the trailing buttons are
                                // intrinsically taller (44px tap padding) than
                                // this Positioned's row band; without an
                                // escape they'd be layout-clamped and their
                                // glyphs top-anchored ~8px low (same failure
                                // as the leading circle). OverflowBox lets the
                                // commands row keep its intrinsic height and
                                // centres it on the band. deferToChild keeps
                                // this box (and the tileBg mask) at the
                                // band-clamped size so the solid background
                                // still covers exactly the title strip.
                                // Hit-testing stays gated by the band's
                                // height, which covers the visible glyphs.
                                // Desktop is an exact fit (30-in-30): no-op.
                                child: OverflowBox(
                                  fit: OverflowBoxFit.deferToChild,
                                  maxHeight: double.infinity,
                                  child: ThreadCommands(
                                    activity: activity,
                                    showCommands: isHighlighted,
                                    showEventTiming: showEventTiming,
                                    bump: bump,
                                    isAssociated: widget.isAssociated,
                                    onDesktopFinish: widget.onDesktopFinish,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
      selected: showSelected,
      // The selected-row outline is drawn by the BlockListSeparator between
      // rows (a single borderFromTheme line, matching the agenda). Suppress
      // the ListTile's own top/bottom selected border so the two don't stack
      // into a thicker, doubled line.
      selectedBorder: false,
      focusNode: focusNode,
      onHover: onHover,
      reorderableIndex: reorderableIndex,
    );

    return listTile;
  }

  @override
  Widget build(BuildContext buildContext) {
    final isTouchDevice = !hasPhysicalKeyboard();
    final rawListTile = _buildListTile(buildContext, isTouchDevice);

    // Dim outside-priority threads (cross-priority calendar events).
    // Remove dimming on hover so the user can read the full content.
    // While a block drag is active, ignore hover so the row doesn't
    // light up like a drop target.
    final rowHovered = _rowHovered && !_isBlockDragging;
    final listTile = widget.isOutsidePriority
        ? MouseRegion(
            onEnter: (_) => setState(() => _rowHovered = true),
            onExit: (_) => setState(() => _rowHovered = false),
            child: Opacity(opacity: rowHovered ? 1.0 : 0.4, child: rawListTile),
          )
        : rawListTile;

    // Desktop: right-click context menu, no drag handle
    if (!isTouchDevice) {
      // Capture the bloc here so commands like Move to priority can fire
      // their optimistic update even when dispatched from a context that has
      // shed the priority page tree.
      final priorityBloc = buildContext.read<PriorityBloc?>();
      return ContextMenu(
        items: (close) =>
            threadCommands(
                  activity,
                  isPlotThread: Thread.isPlotThread(_links),
                  sharingModel: Thread.resolveSharingModel(_links),
                  openInLink: Thread.primaryLink(_links),
                  priorityBloc: priorityBloc,
                )
                .map(
                  (cmd) => FItem(
                    title: Text(cmd.title),
                    prefix: cmd.icon != null
                        ? Icon(cmd.icon, size: buildContext.theme.iconSizes.leading)
                        : null,
                    onPress: () {
                      close();
                      buildContext.run(cmd);
                    },
                  ),
                )
                .toList(),
        child: listTile,
      );
    }

    final swipe = _swipeCommands();
    final swipeRightShort = swipe.rightShort;
    final swipeRightLong = swipe.rightLong;
    final swipeLeftShort = swipe.leftShort;
    final swipeLeftLong = swipe.leftLong;
    final hasSwipeCommands =
        swipeRightShort != null ||
        swipeRightLong != null ||
        swipeLeftShort != null ||
        swipeLeftLong != null;

    // Mobile: long-press on the row starts a reorder drag (handled by the
    // enclosing block-drag or ReorderableDelayedDragStartListener); swipes
    // expose the quick actions and the menu.
    if (hasSwipeCommands) {
      return Swipeable(
        key: ValueKey(activity.id),
        startCommand: swipeRightShort,
        startLongCommand: swipeRightLong,
        endCommand: swipeLeftShort,
        endLongCommand: swipeLeftLong,
        exitOnActivation: widget.onSwipeExit,
        child: listTile,
      );
    }

    return listTile;
  }
}

class ThreadCommands extends HookWidget {
  const ThreadCommands({
    required this.activity,
    this.showCommands = false,
    this.showEventTiming = false,
    this.bump = true,
    this.isAssociated = false,
    this.onDesktopFinish,
    this.onMobileFinish,
    super.key,
  });

  final Thread activity;
  final bool showCommands;
  final bool showEventTiming;
  final bool bump;

  /// True when this thread is rendered nested under an event header in
  /// the agenda. When set and [showCommands] is true, a "Remove from
  /// event" X-icon is appended to the trailing-most position so the
  /// user can detach the thread from the event without disturbing its
  /// own todo state.
  final bool isAssociated;
  final Future<void> Function()? onDesktopFinish;
  final Future<void> Function()? onMobileFinish;

  @override
  Widget build(BuildContext context) {
    // Get commands (only if showCommands is true).
    // Sharing is surfaced by the leading primary-contact avatar (and the
    // header name label), not by a trailing avatar group or a hover share
    // icon, so PickThreadShared is dropped from the hover-command pool.
    final rawHoverCommands = threadCommands(
      activity,
      skipPrimary: true,
      skipInfrequent: true,
      showEventTiming: showEventTiming,
    ).toList();
    // Lead the hover-command row with Schedule, then the remaining frequent
    // commands. Schedule is otherwise only reachable via the leading-icon
    // long-press, so surface it explicitly here. Rename (EditThread) is never
    // shown on hover — it lives only in the more-commands menu. Schedule is a
    // per-user agenda action — allowed even on read-only (announce-group /
    // onboarding) threads, same as the leading-icon long-press — so it is
    // not gated on isReadOnly. PickThreadShared stays filtered out — sharing
    // is reachable via the more-commands menu.
    final hoverCommands = [
      PickScheduleThread(activity),
      ...rawHoverCommands.where(
        (cmd) =>
            cmd is! PickScheduleThread &&
            cmd is! PickThreadShared &&
            cmd is! AssignThread &&
            cmd is! EditThread,
      ),
    ];
    Widget buildCommandButton(Command cmd) => Button.icon(cmd);

    final threadCommandButtons = showCommands
        ? hoverCommands.map(buildCommandButton).toList()
        : <Widget>[];

    // Conferencing/RSVP buttons only for threads shown by their own event
    // timing, not for user-scheduled todos.
    final isTodoBase = activity.todo && !activity.isLinkScheduleInstance;
    final showEventButtons = showEventTiming && !isTodoBase;

    final linksSnapshot = useStream<List<Link>>(
      useMemoized(() => Link.watchForThread(activity.id), [activity.id]),
    );
    final primaryLink = Thread.primaryLink(linksSnapshot.data ?? const []);
    final conferencingActions = showEventButtons
        ? (linksSnapshot.data ?? [])
              .expand((link) => link.actions ?? <UserAction>[])
              .whereType<ConferencingUserAction>()
              .toList()
        : <ConferencingUserAction>[];

    // RSVP chip for calendar events with other invitees. Replaces the old
    // attend/skip/toggle buttons: colour reports the user's own response,
    // body shows the tally, tap opens the picker, hover shows attendees.
    // Solo events (no other invitees) get no RSVP UI.
    final rsvpChip =
        showEventButtons &&
            activity.isLinkScheduleInstance &&
            activity.hasOtherAttendees
        ? RsvpChip(activity: activity)
        : null;

    // Always-on (persistent) trailing icons — anchored at the right edge in a
    // stable position whether or not the row is hovered. Hover-only commands
    // slide in to their LEFT (see [hoverOnly]) instead of reflowing this
    // cluster. Order, left→right: mute (when muted) · conferencing · status ·
    // RSVP · assignee. Mute, when set, lives here (not in the hover set) so it
    // doesn't jump position on hover; it still toggles to unmute on tap.
    final persistent = <Widget>[
      if (activity.muteByThreadId != null)
        buildCommandButton(MuteSimilarThreads(activity)),
      for (final action in conferencingActions)
        _ConferencingIconButton(action: action),
      // Match the always-on icon buttons (size, footprint, hover background).
      if (primaryLink != null)
        StatusIconButton(link: primaryLink, buttonStyle: true),
      ?rsvpChip,
      // Persistent thread-level assignee avatar (any assigned thread).
      if (activity.assigneeId != null) ThreadAssignee(thread: activity),
    ];

    // Hover-only commands — surfaced only while the row is hovered, appearing
    // to the LEFT of the persistent cluster above.
    final hoverOnly = <Widget>[
      if (showCommands) ...[
        ...threadCommandButtons.take(5),
        // Offer "Mute" only when the thread isn't already muted — a muted
        // thread carries the persistent mute icon in the cluster above (which
        // toggles to unmute), so adding it here too would duplicate it.
        if (activity.muteByThreadId == null)
          buildCommandButton(MuteSimilarThreads(activity)),
        // Surface "Assign" on hover for unassigned, writable threads. Assigned
        // threads get the persistent trailing [ThreadAssignee] avatar instead.
        if (activity.assigneeId == null && !activity.isReadOnly)
          Button.icon(AssignThread(activity)),
        // "Remove from event" X-icon for associated threads — a hover-only
        // action, so it sits with the other hover commands to the left of the
        // persistent cluster.
        if (isAssociated) Button.icon(DisassociateThread(activity)),
        // Rename is intentionally NOT surfaced on hover — it lives only in the
        // more-commands menu, and only for Plot threads (see threadCommands).
        // Always end with the more-commands overflow menu.
        Button.icon(
          CommandWrapper(
            ShowThreadCommands(activity),
            icon: Value(PlotIcon.more),
          ),
        ),
      ],
    ];

    // The trailing row is overlaid via a [Positioned] (see _buildListTile)
    // whose negative right offset is tuned for ghost icon buttons so the visible
    // glyph lands at the content's right edge (aligned with the header
    // timestamp). Bare trailing items — the RSVP chip and a *read-only* assignee
    // avatar — carry no such internal inset and would overshoot to the panel
    // edge, so they get a compensating inset. A *writable* assignee avatar is
    // itself a padded ghost button and already hugs the edge, so it must not be
    // inset again. Computed independent of hover so the chip/avatar holds its
    // position when hover commands appear. See [trailingClusterInset].
    final trailingInset = trailingClusterInset(
      hasRsvpChip: rsvpChip != null,
      hasAssignee: activity.assigneeId != null,
      assigneeIsReadOnly: activity.isReadOnly,
      ghostIconPadding: context
          .theme
          .buttonStyles
          .ghost
          .md
          .iconContentStyle
          .padding
          .resolve(TextDirection.ltr)
          .right,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...hoverOnly,
        ...persistent,
        if (trailingInset > 0) SizedBox(width: trailingInset),
      ],
    );
  }
}

class _ConferencingIconButton extends StatelessWidget {
  const _ConferencingIconButton({required this.action});

  final ConferencingUserAction action;

  @override
  Widget build(BuildContext context) {
    final tooltip = switch (action.provider) {
      ConferencingProvider.googleMeet => 'Join Google Meet',
      ConferencingProvider.zoom => 'Join on Zoom',
      ConferencingProvider.microsoftTeams => 'Join on Teams',
      ConferencingProvider.webex => 'Join Webex',
      ConferencingProvider.other => 'Join Meeting',
    };

    return FTooltip(
      tipBuilder: (context, controller) => Text(tooltip),
      child: FButton.icon(
        variant: FButtonVariant.ghost,
        onPress: () {
          try {
            launchUrl(
              Uri.parse(action.url),
              mode: LaunchMode.externalApplication,
            );
          } catch (_) {}
        },
        child: Icon(PlotIcon.video, size: context.theme.iconSizes.base),
      ),
    );
  }
}

/// Which colour the RSVP chip wears, driven by the current user's own
/// response. Tentative and no-response both read neutral.
enum RsvpTone { going, declined, neutral }

/// Interactive RSVP chip: shows the attendee tally (non-zero count segments)
/// tinted by the user's own status; tap opens the RSVP picker; hover shows
/// the grouped attendee details. Only render when [activity.hasOtherAttendees].
class RsvpChip extends StatefulWidget {
  const RsvpChip({required this.activity, this.fontSize, super.key});

  final Thread activity;
  final double? fontSize;

  /// The user's own status → chip tone.
  static RsvpTone toneFor(String? currentUserRsvp) => switch (currentUserRsvp) {
    'attend' => RsvpTone.going,
    'skip' => RsvpTone.declined,
    _ => RsvpTone.neutral,
  };

  /// Ordered, non-zero count segments (going, declined, undecided).
  static List<({IconData icon, int count})> segmentsFor(
    ({int attend, int skip, int undecided}) counts,
  ) => [
    if (counts.attend > 0) (icon: PlotIcon.rsvpGoing, count: counts.attend),
    if (counts.skip > 0) (icon: PlotIcon.rsvpDeclined, count: counts.skip),
    if (counts.undecided > 0)
      (icon: PlotIcon.rsvpUndecided, count: counts.undecided),
  ];

  @override
  State<RsvpChip> createState() => _RsvpChipState();
}

class _RsvpChipState extends State<RsvpChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final segments = RsvpChip.segmentsFor(widget.activity.rsvpCounts);
    if (segments.isEmpty) return const SizedBox.shrink();

    final fontSize =
        widget.fontSize ?? context.theme.typography.xs.fontSize ?? 13;

    // The user's own status drives the colour. Content (icons + numbers) is the
    // muted status colour; a faint same-hue border frames the pill. The fill
    // base uses fuller chroma for "going" so its green tint reads as saturated
    // as the rose "declined". Hover deepens the border (+ a soft glow).
    final (Color content, Color fillBase) = switch (RsvpChip.toneFor(
      widget.activity.currentUserRsvp,
    )) {
      RsvpTone.going => (
        context.colour.colours.fromTheme(const ThemeColor(0), muted: true),
        context.colour.colours.fromTheme(const ThemeColor(0)),
      ),
      RsvpTone.declined => (
        context.colour.colours.fromTheme(const ThemeColor(5), muted: true),
        context.colour.colours.fromTheme(const ThemeColor(5), muted: true),
      ),
      RsvpTone.neutral => (context.colour.muted, context.colour.muted),
    };

    // The fill is a translucent same-hue tint. In dark mode a flat 10% wash of
    // the (dark) base over the dark surface reads well, so it's kept as-is. In
    // light mode that same wash turns dark and grey — the base is dark and
    // little of its chroma survives at such low alpha — so the tint is rebuilt
    // from a light, saturated pastel of the same hue laid down at a higher
    // alpha. The fill stays constant across hover in both modes: over a pale
    // surface a heavier tint only reads darker (away from white), never more
    // vivid, so hover is signalled by the deepened border + glow instead.
    final Color fill;
    if (context.colour.brightness == Brightness.light) {
      final base = fillBase.toRayRgb8().toOklch();
      final pastel = base
          .withLightness(0.85)
          .withChroma(base.chroma * 1.2)
          .toColor();
      fill = pastel.withValues(alpha: 0.20);
    } else {
      fill = fillBase.withValues(alpha: 0.10);
    }
    final borderColor = content.withValues(alpha: _hovered ? 0.5 : 0.3);

    // The pill sits a little taller than its text so the icon + number have a
    // bit of vertical breathing room. The factor stays under the agenda's
    // fixed row-2 box, which is sized for the larger sm text (secondarySize *
    // 1.25 ≈ fontSize * 1.46 when the chip renders at xs): the pill fills more
    // of that box without overflowing or growing the row. In the thread footer
    // it sits well inside the taller button row. The border is painted inside,
    // adding no extra height.
    final height = fontSize * 1.4;
    final iconSize = fontSize * 0.82;
    final gap = fontSize * 0.5;

    final chip = Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: fontSize * 0.5),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: borderColor, width: 1),
        borderRadius: BorderRadius.circular(height / 2),
        boxShadow: _hovered
            ? [
                BoxShadow(
                  color: content.withValues(alpha: 0.18),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            FaIcon(segments[i].icon, size: iconSize, color: content),
            SizedBox(width: fontSize * 0.22),
            Text(
              '${segments[i].count}',
              style: TextStyle(
                color: content,
                fontSize: fontSize,
                height: 1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );

    final interactive = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          context.run(ShowRsvpOptions(widget.activity));
        },
        child: chip,
      ),
    );

    final contacts = widget.activity.scheduleContacts;
    if (contacts.isEmpty) return interactive;
    return FTooltip(
      tipBuilder: (context, controller) => RsvpDetails(contacts: contacts),
      child: interactive,
    );
  }
}

class _ThreadLogo extends StatelessWidget {
  const _ThreadLogo({required this.activity});

  final Thread activity;

  @override
  Widget build(BuildContext context) {
    final brightness = context.colour.brightness;

    // Plot threads show the Plot mark unless the thread has its own source
    // icon (twist, connector, URL).
    if (_hasNoExplicitSource) {
      return SvgPicture.asset('assets/plot-icon.svg', width: 16, height: 16);
    }

    final resolved = Thread.resolveIcon(activity.icon);
    final logoUrl = brightness == Brightness.dark
        ? (resolved.logoDarkUrl ?? resolved.logoUrl)
        : resolved.logoUrl;

    if (logoUrl != null && !LogoCache.isFailed(logoUrl)) {
      return Opacity(
        opacity: brightness == Brightness.dark ? 0.7 : 0.9,
        child: LogoImage(url: logoUrl),
      );
    }
    return Icon(
      resolved.fallbackIcon,
      size: 16,
      color: context.theme.plotColors.veryMuted,
    );
  }

  bool get _hasNoExplicitSource {
    final icon = activity.icon;
    if (icon == null) return true;
    if (icon.startsWith('twist:')) return false;
    if (icon.startsWith('connector:')) return false;
    if (icon.startsWith('http')) return false;
    return true;
  }
}

/// Read-only rendering of a thread's header, source logo, title and inline
/// preview — the same visual language as [ThreadWidget] minus the feed chrome
/// (leading todo icon, swipe, hover commands, navigation). Used where a thread
/// must be shown for recognition only, e.g. the focus-creation match picker.
///
/// Reuses [ThreadWidget]'s building blocks: the [_ThreadLogo] source icon,
/// [Thread.displayTitle]/[Thread.displayPreview], the channel breadcrumb and
/// the participant-name header (with the author promoted to the front).
class ThreadSummary extends StatefulWidget {
  const ThreadSummary({required this.thread, super.key});

  final Thread thread;

  @override
  State<ThreadSummary> createState() => _ThreadSummaryState();
}

class _ThreadSummaryState extends State<ThreadSummary> {
  StreamSubscription<List<Link>>? _linksSub;
  List<Link> _links = const [];
  Map<Uuid, Actor> _actors = const {};

  Thread get thread => widget.thread;

  @override
  void initState() {
    super.initState();
    _links = Link.cachedForThread(thread.id) ?? const [];
    _linksSub = Link.watchForThread(thread.id).listen((links) {
      if (!mounted) return;
      setState(() => _links = links);
    });
    _loadActors();
  }

  @override
  void dispose() {
    _linksSub?.cancel();
    super.dispose();
  }

  void _loadActors() {
    final ids = _otherContactIds();
    () async {
      final resolved = <Uuid, Actor>{};
      for (final id in ids) {
        try {
          resolved[id] = await Actor.getOne(ActorId.fromUuid(id));
        } catch (_) {
          // Skip contacts whose actors can't be resolved.
        }
      }
      if (!mounted) return;
      setState(() => _actors = resolved);
    }();
  }

  bool get _isChannelThread =>
      Thread.resolveSharingModel(_links) == SharingModel.channel;

  /// Channel breadcrumb (e.g. "Acme Co › #general"), or null when the primary
  /// link isn't channel-sharing. Mirrors [ThreadWidget]'s `_channelLabel`.
  String? _channelLabel() {
    if (!_isChannelThread) return null;
    final primary = Thread.primaryLink(_links);
    final ptId = primary?.createdBy;
    if (ptId == null) return null;
    final instance = TwistInstance.fromCache(ptId);
    final workspace = (instance?.accountLabel?.isNotEmpty ?? false)
        ? instance!.accountLabel
        : instance?.name;
    final channelId = primary!.channelId;
    final channel = channelId != null
        ? Channel.findByChannel(ptId, channelId)?.title
        : null;
    return formatChannelBreadcrumb(workspace: workspace, channel: channel);
  }

  /// Other contacts in thread order (author promoted to front), excluding the
  /// current user, dropped contacts, and connection-source twists. Mirrors
  /// [ThreadWidget]'s `_otherContactIds`.
  List<Uuid> _otherContactIds() {
    final self = Actor.getCurrentUserActorIds().map((a) => a.toUuid()).toSet();
    final dropped = thread.droppedContacts.toSet();
    final out = <Uuid>[];
    final seen = <Uuid>{};
    for (final id in thread.contacts) {
      if (self.contains(id)) continue;
      if (dropped.contains(id)) continue;
      if (TwistInstance.fromCache(id)?.isSource ?? false) continue;
      if (seen.add(id)) out.add(id);
    }
    final authorId = thread.authorId?.toUuid();
    if (authorId != null && !self.contains(authorId)) {
      final index = out.indexOf(authorId);
      if (index > 0) {
        out.removeAt(index);
        out.insert(0, authorId);
      }
    }
    return out;
  }

  /// Comma-joined participant names (author first), or null. Mirrors
  /// [ThreadWidget]'s `_contactsLabel`.
  String? _contactsLabel() {
    if (_isChannelThread) return null;
    final names = <String>[];
    for (final id in _otherContactIds()) {
      final actor = _actors[id] ?? Actor.fromCache(ActorId.fromUuid(id));
      if (actor != null) names.add(actor.nameOrEmail);
    }
    if (names.isEmpty) return null;
    return names.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final header = _channelLabel() ?? _contactsLabel();
    final preview = thread.displayPreview;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (header != null)
          Padding(
            padding: EdgeInsets.only(bottom: context.theme.spacing.xs),
            child: Text(
              header,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.theme.colors.mutedForeground,
                fontSize: context.theme.typography.xs.fontSize,
                height: 1,
              ),
            ),
          ),
        Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: _ThreadLogo(activity: thread),
            ),
            SizedBox(width: context.theme.spacing.md),
            Expanded(
              child: Text.rich(
                overflow: TextOverflow.ellipsis,
                style: context.theme.typography.md.copyWith(
                  color: context.colour.foreground,
                ),
                TextSpan(
                  children: [
                    TextSpan(text: thread.displayTitle),
                    if (preview != null &&
                        preview.isNotEmpty &&
                        preview != thread.displayTitle)
                      TextSpan(
                        text: '  $preview',
                        style: TextStyle(color: context.colour.muted),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ThreadLeadingCommand extends CommandWrapper {
  final IconData outlineIcon;
  final bool showEmpty;
  final Color? dotColor;
  final bool dotOverOutline;
  final Color? iconHoverColor;

  _ThreadLeadingCommand(
    super.command, {
    required this.outlineIcon,
    this.showEmpty = false,
    this.dotColor,
    this.dotOverOutline = false,
    this.iconHoverColor,
    super.hoverIcon,
    super.title,
  }) : super(icon: Value(outlineIcon));

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) {
    final baseSize = context.theme.iconSizes.base;
    if (hoverIcon) {
      // Apply foreground color directly since IgnorePointer prevents
      // FButton from detecting its own hover state.
      if (iconHoverColor != null) {
        return Icon(
          this.hoverIcon ?? outlineIcon,
          size: baseSize,
          color: iconHoverColor,
        );
      }
      return null;
    }
    if (dotColor != null) {
      final dot = CustomPaint(
        size: const Size.square(6),
        painter: _DotPainter(color: dotColor!),
      );
      return SizedBox(
        width: baseSize,
        height: baseSize,
        child: dotOverOutline
            ? Stack(
                alignment: Alignment.center,
                children: [
                  Icon(outlineIcon, size: baseSize),
                  dot,
                ],
              )
            : Center(child: dot),
      );
    }
    if (showEmpty) {
      return SizedBox(width: baseSize, height: baseSize);
    }
    return null;
  }
}

/// Replaces the small thread logo when the row is hovered, surfacing the
/// edit-thread action without crowding the trailing command row.
class _MoveHoverIcon extends StatefulWidget {
  const _MoveHoverIcon({required this.activity});

  final Thread activity;

  @override
  State<_MoveHoverIcon> createState() => _MoveHoverIconState();
}

class _MoveHoverIconState extends State<_MoveHoverIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final command = MoveThreadToPriority(widget.activity);
    final iconData = PlotIcon.move;
    final shortcutText = hasPhysicalKeyboard() && command.shortcut != null
        ? formatShortcut(command.shortcut)
        : '';
    return FTooltip(
      tipBuilder: (ctx, controller) {
        if (shortcutText.isNotEmpty) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(command.title),
              Text(
                shortcutText,
                style: ctx.theme.typography.xs.copyWith(
                  color: ctx.theme.colors.mutedForeground,
                ),
              ),
            ],
          );
        }
        return Text(command.title);
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.run(command),
          onLongPress: () async {
            // Rename is restricted to Plot threads (user- or non-connection-
            // twist-created); connector-created threads take their title from
            // the source. See Thread.isPlotThread.
            final links = await Link.getForThread(widget.activity.id);
            if (!Thread.isPlotThread(links)) return;
            if (context.mounted) context.run(EditThread(widget.activity));
          },
          child: Center(
            child: FaIcon(
              iconData,
              size: 14,
              color: _hovered
                  ? context.colour.foreground
                  : context.colour.muted,
            ),
          ),
        ),
      ),
    );
  }
}

class _DotPainter extends CustomPainter {
  _DotPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width / 2,
      paint,
    );
  }

  @override
  bool shouldRepaint(_DotPainter oldDelegate) => color != oldDelegate.color;
}

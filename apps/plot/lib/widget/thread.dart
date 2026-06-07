import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:prism_flutter/prism_flutter.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/logo_cache.dart';
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/widget/thread_assignee.dart';
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
}) =>
    !isChannelThread &&
    hasContactIds &&
    (!actorsLoaded || hasResolvedLabel);

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
    this.showEventTiming = false,
    this.bump = true,
    this.focusNode,
    this.onHover,
    this.reorderableIndex,
    this.onSwipeExit,
    this.onDesktopFinish,
    this.onMobileFinish,
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

  @override
  State<ThreadWidget> createState() => _ThreadWidgetState();
}

class _ThreadWidgetState extends State<ThreadWidget> {
  bool _leadingHovered = false;
  bool _rowHovered = false;
  BlockDragController? _dragController;

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
    _dragController?.removeListener(_onDragChanged);
    super.dispose();
  }

  /// The channel breadcrumb for this thread, or null when the primary
  /// (earliest-created) link is not channel-sharing — the same "primary" link
  /// that [Thread.resolveSharingModel] keys on. Resolved from the in-memory
  /// [TwistInstance]/[Channel] caches, falling back to whichever part resolves.
  String? _channelLabel() {
    if (_links.isEmpty) return null;
    if (Thread.resolveSharingModel(_links) != SharingModel.channel) return null;
    final primary = ([
      ..._links,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt))).first;
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
  bool get showEventTiming => widget.showEventTiming;
  bool get bump => widget.bump;
  FocusNode? get focusNode => widget.focusNode;
  void Function(bool hovered)? get onHover => widget.onHover;
  int? get reorderableIndex => widget.reorderableIndex;

  // Short right: Toggle active. Universal "deal with this now" — flips
  // active on so the thread lands in Doing (or off, mirroring the leading
  // icon tap on desktop).
  Command? _getSwipeRightShortCommand() {
    if (widget.isOutsidePriority) return null;
    return ToggleThreadActive(activity);
  }

  // Long right: Schedule for another day.
  Command? _getSwipeRightLongCommand() {
    if (widget.isOutsidePriority) return null;
    return PickScheduleThread(activity);
  }

  // Short left: Finish (only for scheduled/todo threads — inert on
  // unscheduled threads, the user must reach the long zone for the menu).
  Command? _getSwipeLeftShortCommand() {
    if (widget.isOutsidePriority) return null;
    if (!activity.todo) return null;
    return FinishThread(
      activity,
      bump: bump,
      // Link schedule instances stay visible after finish, so skip removal
      // animation. For swipe, the non-link-schedule path uses an empty
      // callback so onSwipeExit handles the visual removal instead.
      onBeforeRun: activity.isLinkScheduleInstance
          ? null
          : widget.onSwipeExit != null
          ? (_) async {}
          : null,
    );
  }

  // Long left: Menu. Universal across all list views. Less-frequent actions
  // are accessible from here.
  Command? _getSwipeLeftLongCommand() {
    if (widget.isOutsidePriority) return null;
    return ShowThreadCommands(activity);
  }

  Widget _buildListTile(BuildContext buildContext, bool isTouchDevice) {
    final hasSubPriorityLabel =
        showSubPriority &&
        priorityContext != null &&
        activity.priority.id != priorityContext!.id;

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

    // When a priority label is shown above the title row, compute its
    // rendered height + the 2px gap so we can push leading/trailing down
    // by the same amount, keeping them vertically centred with the title.
    final labelOffset = hasTopLabel
        ? (TextPainter(
            text: TextSpan(
              text: 'A',
              style: TextStyle(
                fontSize: buildContext.theme.typography.xs.fontSize,
                height: 1,
              ),
            ),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          )..layout()).height
        : 0.0;

    final threadColor = buildContext.colour.colours.fromTheme(
      activity.priority.displayColor,
    );
    final selectedBg = buildContext.colour.colours.backgroundFromTheme(
      activity.priority.displayColor,
    );

    final listTile = ListTile(
      command: CommandWrapper(ChangeCurrentThread(activity), icon: Value(null)),
      // Bypass ListTile's run() spinner tracking. The command returns
      // CommandDone immediately (navigation is fire-and-forget), but routing
      // it through context.run directly keeps the spinner machinery out of
      // the hot tap path entirely.
      onTap: () {
        buildContext.run(ChangeCurrentThread(activity));
      },
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

        // Leading button: unified-feed state icon.
        //   - !active resting: nothing visible.
        //   - !active hovered: `circlePlus` with "To do" tooltip; tap sets
        //                      active=true (lands in Doing).
        //   - active resting:  `circle`.
        //   - active hovered:  `circleCheck` with "Done" tooltip; tap
        //                      clears active and marks read (lands in
        //                      Activity).
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

        final Widget todoIcon;
        final String leadingTitle = !isTodo ? 'To do' : 'Done';
        final iconHoverColor = leadingHovered
            ? buildContext.colour.foreground
            : buildContext.colour.muted;
        if (!isTodo) {
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
          // Active: circle at rest; circleCheck on hover. Unread overlays
          // a centered dot on the circle.
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
            forceHover: isHovered,
            onLongPress: longPress,
          );
        }

        return SizedBox(
          width: leadingW,
          child: Padding(
            padding: EdgeInsets.only(
              top: spacing.sm + labelOffset,
              bottom: spacing.sm,
            ),
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
                // Centered icon (visual only)
                Center(child: IgnorePointer(child: todoIcon)),
              ],
            ),
          ),
        );
      },
      bodyBuilder: (buildCtx, rawHighlighted) {
        // While a block drag is in progress, treat the thread as not
        // highlighted so it doesn't render edit affordances or the
        // ThreadCommands row that would make it look like a drop target.
        final isHighlighted = _isBlockDragging ? false : rawHighlighted;
        // State-dependent colors – only selection unmutes foreground;
        // hover should not change any foreground colors.
        final headerFg = selected ? threadColor : null;

        // Opaque composited bg for ThreadCommands gradient
        final compositedBg = selected
            ? selectedBg
            : isHighlighted
            ? buildContext.colour.editableBackground
            : buildContext.colour.background;

        return Padding(
          padding: EdgeInsets.only(
            top: buildContext.theme.spacing.sm,
            bottom: buildContext.theme.spacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasTopLabel)
                DefaultTextStyle(
                  style: TextStyle(
                    color:
                        headerFg ?? buildContext.theme.colors.mutedForeground,
                    fontSize: buildContext.theme.typography.xs.fontSize,
                    height: 1,
                  ),
                  child: Builder(
                    builder: (context) {
                      // Header segments in order: channel · focus · schedule.
                      // Each present segment is joined to the previous with a
                      // dot separator below.
                      final segments = <Widget>[
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
                        if (hasSubPriorityLabel)
                          Flexible(
                            child: _PriorityHoverArea(
                              activity: activity,
                              priorityContext: priorityContext,
                              headerFg: headerFg,
                              fontSize: context.theme.typography.xs.fontSize,
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
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < segments.length; i++) ...[
                            if (i > 0) const Text(' · '),
                            segments[i],
                          ],
                        ],
                      );
                    },
                  ),
                ),
              // SizedBox + Stack keeps the title row height stable
              // regardless of whether ThreadCommands buttons are
              // visible. The fixed height matches FButton.icon (icon
              // size + icon-content padding) so it equals the leading
              // button area. This prevents layout shifts when
              // ThreadCommands appears on hover, and keeps the Stack
              // tall enough for buttons to receive hit-test events
              // (RenderBox.hitTest rejects positions outside its
              // size, so the Stack must be at least as tall as the
              // buttons for per-button hover to work).
              SizedBox(
                height:
                    buildContext.theme.iconSizes.base +
                    buildContext
                        .theme
                        .buttonStyles
                        .ghost
                        .md
                        .iconContentStyle
                        .padding
                        .resolve(TextDirection.ltr)
                        .vertical,
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
                              ),
                              TextSpan(
                                children: [
                                  // Broom indicator for threads swept up by
                                  // a "Skip active for threads like this"
                                  // mute rule. Surfaced on any muted thread
                                  // so the user can identify rule-anchored
                                  // rows in the unified feed.
                                  if (activity.muteByThreadId != null)
                                    WidgetSpan(
                                      alignment: PlaceholderAlignment.middle,
                                      child: Padding(
                                        padding: EdgeInsets.only(
                                          right: buildContext.theme.spacing.xs,
                                        ),
                                        child: Icon(
                                          PlotIcon.broom,
                                          size: 12,
                                          color: buildContext.colour.muted,
                                        ),
                                      ),
                                    ),
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
                                        : selected
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
                      // Push the trailing row right enough that its icon
                      // glyphs / avatars line up with the right edge of
                      // header durations (block headers end at
                      // `spacing.lg` from the agenda edge — same as the
                      // ListTile's right padding — so we offset by the
                      // button's own internal icon padding to land the
                      // visible glyph/avatar right at that boundary).
                      right:
                          -buildContext
                              .theme
                              .buttonStyles
                              .ghost
                              .md
                              .iconContentStyle
                              .padding
                              .resolve(TextDirection.ltr)
                              .right -
                          buildContext.theme.spacing.xs,
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
                                child: ThreadCommands(
                                  activity: activity,
                                  showCommands: isHighlighted,
                                  showEventTiming: showEventTiming,
                                  bump: bump,
                                  isAssociated: widget.isAssociated,
                                  onDesktopFinish: widget.onDesktopFinish,
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
      selected: selected,
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
        items: (close) => threadCommands(
              activity,
              isPlotThread: Thread.isPlotThread(_links),
              sharingModel: Thread.resolveSharingModel(_links),
              priorityBloc: priorityBloc,
            )
            .map(
              (cmd) => FItem(
                title: Text(cmd.title),
                prefix: cmd.icon != null ? Icon(cmd.icon, size: 16) : null,
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

    final swipeRightShort = _getSwipeRightShortCommand();
    final swipeRightLong = _getSwipeRightLongCommand();
    final swipeLeftShort = _getSwipeLeftShortCommand();
    final swipeLeftLong = _getSwipeLeftLongCommand();
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

    final List<Widget> allButtons;
    if (showCommands) {
      allButtons = [
        ...threadCommandButtons.take(5),
        // "Skip active for threads like this" sits immediately before the
        // overflow menu so it's always reachable on hover. Title and event
        // semantics flip based on whether the thread already carries the
        // mute flag.
        Button.icon(MuteSimilarThreads(activity)),
        // Surface "Assign" on hover for unassigned, writable threads. Assigned
        // threads get the persistent trailing [ThreadAssignee] avatar instead.
        if (activity.assigneeId == null && !activity.isReadOnly)
          Button.icon(AssignThread(activity)),
        // Rename is intentionally NOT surfaced on hover — it lives only in the
        // more-commands menu, and only for Plot threads (see threadCommands).
        // Always add ShowThreadCommands as the 6th button
        Button.icon(
          CommandWrapper(
            ShowThreadCommands(activity),
            icon: Value(PlotIcon.more),
          ),
        ),
      ];
    } else {
      // Mute toggle is treated like an enabled tag: when the flag is set the
      // icon stays visible even when the row isn't hovered (hover surfaces
      // the full command set, including it — so no duplication).
      allButtons = [
        if (activity.muteByThreadId != null)
          buildCommandButton(MuteSimilarThreads(activity)),
      ];
    }

    // The trailing row is overlaid via a [Positioned] (see _buildListTile)
    // whose negative right offset is tuned for ghost icon buttons: it pushes
    // the row right by the button's internal icon padding so the visible glyph
    // lands at the content's right edge. Non-button trailing items (the RSVP
    // chip, the assignee avatar) carry no such internal inset, so when one of
    // them is the trailing-most child it overshoots and sits flush against the
    // panel edge. When resting (no hover commands, which always end in a
    // button), add a right inset equal to that button icon padding so the
    // chip/avatar lands at the same x a button glyph would — matching the
    // agenda's RSVP padding.
    final trailingIsNonButton =
        !showCommands && (rsvpChip != null || activity.assigneeId != null);
    final trailingInset = trailingIsNonButton
        ? context
              .theme
              .buttonStyles
              .ghost
              .md
              .iconContentStyle
              .padding
              .resolve(TextDirection.ltr)
              .right
        : 0.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...allButtons,
        for (final action in conferencingActions)
          _ConferencingIconButton(action: action),
        ?rsvpChip,
        // Persistent thread-level assignee avatar (any assigned thread).
        if (activity.assigneeId != null) ThreadAssignee(thread: activity),
        // Trailing-most "Remove from event" X-icon for associated
        // threads, surfaced only on hover. The row is positioned at
        // the right edge with mainAxisSize.min, so adding this as
        // the last child pushes existing trailing items (tags,
        // avatars) to the left.
        if (isAssociated && showCommands)
          Button.icon(DisassociateThread(activity)),
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

/// Wraps the priority label in the top-of-row meta strip with a hover state
/// and a trailing veryMuted select icon. Hover unmutes the label and tints
/// the select icon with the accent colour; clicking anywhere in the area
/// opens the move modal.
class _PriorityHoverArea extends StatefulWidget {
  const _PriorityHoverArea({
    required this.activity,
    required this.priorityContext,
    required this.headerFg,
    required this.fontSize,
  });

  final Thread activity;
  final Priority? priorityContext;
  final Color? headerFg;
  final double? fontSize;

  @override
  State<_PriorityHoverArea> createState() => _PriorityHoverAreaState();
}

class _PriorityHoverAreaState extends State<_PriorityHoverArea> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final command = MoveThreadToPriority(widget.activity);
    final shortcutText = hasPhysicalKeyboard() && command.shortcut != null
        ? formatShortcut(command.shortcut)
        : '';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: FTooltip(
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
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.run(command),
          child: FocusLabel(
            priority: widget.activity.priority,
            color: widget.headerFg,
            fontSize: widget.fontSize,
            height: 1,
            muted: widget.headerFg == null && !_hovered,
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

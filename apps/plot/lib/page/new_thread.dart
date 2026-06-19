import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/widget/priorities_shell.dart' show BottomNavInset;
import 'package:plot/state/priority.dart';
import 'package:plot/state/priorities.dart';

import 'package:plot/state/compose_targets.dart';
import 'package:plot/widget/compose/compose_sections_view.dart';
import 'package:plot/widget/compose/compose_pill.dart'
    show ComposePillData, ContactPillData, GroupPillData, AdHocGroupPillData;
import 'package:plot/widget/compose/connection_picker_view.dart';
import 'package:plot/screenshot/scenes.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/command/command.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/page/priority.dart'
    show ActivityPanelControllerProvider, PriorityShortcutsProviderState;
import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/link_type_copy.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/url_title.dart' show fetchUrlMetadata;
import 'package:plot/share_intent.dart' show extractHttpUrl;
import 'package:plot/analytics/tracker.dart';
import 'logging.dart';

/// Opacity of the new-thread panel content in its "inactive" (resting) state —
/// muted by one step so it doesn't catch the eye when not in use. 1.0 is the
/// "active" state. Tunable; "one step" is subjective. See [NewThreadPageState].
const double kNewThreadInactiveOpacity = 0.55;

/// Returns [note] with an [ExternalUserAction] for [url] appended (deduped by
/// url). When an action for [url] already exists it is replaced with the
/// upgraded title/favicon. Pure — used by the new-thread URL/link flow.
Note appendExternalLink(
  Note note, {
  required String url,
  String? title,
  String? favicon,
}) {
  final actions = [...(note.actions ?? const <UserAction>[])];
  final action = ExternalUserAction(
    title: (title != null && title.isNotEmpty) ? title : url,
    url: url,
    favicon: favicon,
  );
  final idx = actions.indexWhere(
    (a) => a is ExternalUserAction && a.url == url,
  );
  if (idx >= 0) {
    actions[idx] = action;
  } else {
    actions.add(action);
  }
  return note.copyWith(actions: actions);
}

/// Decides the focus ranking [_NewThreadPageState._suggestFocusForTarget]
/// applies for a chosen [ComposeTarget], given the roster-specific focus MRU
/// ([rosterRank]) and the global focus MRU ([globalRank]). The first id (if
/// any) is pre-selected; the rest seed the focus picker order. An empty result
/// means "leave the draft on its current focus" (no switch). Pure.
///
/// - **Roster history wins**: file under the focus the user last used with this
///   exact roster.
/// - A **roster-bearing** target with no roster history keeps the current focus
///   (returns empty). The global MRU would yank a thread addressed to a person
///   / email into an unrelated focus — surprising when the user is composing
///   from a specific focus. This is the case behind "it picked a focus other
///   than the current one" for a freshly typed recipient.
/// - Only a **no-roster** (Note-like) target falls back to the global MRU,
///   where there is no "who" to file by, so the most-recently-used focus is the
///   sensible default.
List<Uuid> suggestedFocusRanking({
  required List<Uuid> rosterRank,
  required List<Uuid> globalRank,
  required bool hasRoster,
}) {
  if (rosterRank.isNotEmpty) return rosterRank;
  if (hasRoster) return const [];
  return globalRank;
}

@RoutePage(name: "NewThreadWrapperRoute")
class NewThreadWrapper implements AutoRouteWrapper {
  const NewThreadWrapper();

  @override
  Widget wrappedRoute(BuildContext context) {
    return AutoRouter(placeholder: (context) => const LoadingPage());
  }
}

@RoutePage()
class NewThreadPage extends StatefulWidget {
  const NewThreadPage({
    super.key,
    @QueryParam('startTime') this.startTime,
    @QueryParam('endTime') this.endTime,
    @QueryParam('duration') this.duration,
    @QueryParam('priorityId') this.priorityId,
    @QueryParam('sharedUrl') this.sharedUrl,
    @QueryParam('feedback') this.feedback,
  });

  final String? startTime;
  final String? endTime;
  final int? duration; // Duration in minutes
  final String? priorityId;
  final String? sharedUrl;

  /// When true (set by the Help & Feedback command), the draft is pre-shared
  /// with the Plot Team group so the new Inbox thread reaches the Plot team.
  ///
  /// Nullable so the route only serialises `?feedback=true` when set — a
  /// non-null `false` default would append a redundant `?feedback=false` to
  /// every normal new-thread URL (auto_route drops null/empty query values,
  /// not `false`).
  final bool? feedback;

  @override
  State<NewThreadPage> createState() => NewThreadPageState();
}

/// The three phases of the new-thread compose flow.
///
/// [sections] is step 1: the inline sections picker (people & twists, channels,
/// and private-note focuses). Picking a people pill advances to [connection]
/// (step 2: choose which connection to reach that recipient through); picking a
/// twist/channel/focus skips straight to [compose]. [compose] is the final
/// step: today's compose surface with the editor focused and fields ordered
/// Connection → Focus → Contacts → Title → Body. A fresh mount always starts in
/// [sections] (see [NewThread] command).
enum _ComposeStep { sections, connection, compose }

class NewThreadPageState extends State<NewThreadPage> {
  /// Monotonic "start a fresh new-thread" signal. The [NewThread] command
  /// bumps this every time it's invoked. AutoRoute reuses an already-mounted
  /// [NewThreadPage]/[State] when navigating to [NewThreadRoute] (it doesn't
  /// build a new one), so a live page would otherwise keep its in-progress
  /// `_step`/draft. Listening to this counter lets the live page reset itself
  /// to step 1 with a fresh draft. On a true fresh mount there's no listener
  /// yet, so the page just starts clean as usual.
  static final ValueNotifier<int> resetRequest = ValueNotifier<int>(0);

  /// Requests every live [NewThreadPage] reset to step 1 with a fresh draft.
  static void requestReset() => resetRequest.value++;

  /// Monotonic "enter Help & Feedback mode" signal, mirroring [resetRequest].
  /// The [HelpAndFeedback] command bumps this so a live (AutoRoute-reused)
  /// page reconfigures itself for feedback (see [_applyFeedbackMode]); a fresh
  /// mount instead reacts to the `feedback` route param in [_initializeDraft].
  static final ValueNotifier<int> feedbackRequest = ValueNotifier<int>(0);

  /// Requests every live [NewThreadPage] enter Help & Feedback mode.
  static void requestFeedback() => feedbackRequest.value++;

  /// The currently-mounted [NewThreadPage] state, or null when no new-thread
  /// page is live. Set in [didChangeDependencies] / cleared in [dispose] so
  /// other widgets (e.g. the unified header's search-close focus-restore) can
  /// ask whether the new-thread page is on step 1 and, if so, hand focus to its
  /// inline filter instead of the (unmounted) note editor. Mirrors the
  /// [requestReset]/[resetRequest] static-signal pattern.
  static NewThreadPageState? _live;

  /// True when a [NewThreadPage] is live and showing step 1 (the inline target
  /// picker). Lets the search-close focus-restore path branch to the filter
  /// input rather than the note editor (which isn't mounted on step 1).
  static bool get isOnStep1 =>
      _live != null && _live!.mounted && _live!._step == _ComposeStep.sections;

  /// Focuses the live step-1 inline filter input on the next frame. No-op when
  /// no page is live, the page isn't on step 1, or there's no physical keyboard
  /// (consistent with the picker's own autofocus gating — never pops the mobile
  /// soft keyboard). Used by the search-close focus-restore path in place of
  /// focusing the note editor when [isOnStep1].
  static void focusFilter() {
    final live = _live;
    if (live == null || !live.mounted) return;
    if (live._step != _ComposeStep.sections) return;
    live._focusPickerSearch(_ComposeStep.sections);
  }

  final GlobalKey<NoteEditorState> _threadEditorKey =
      GlobalKey<NoteEditorState>();
  final GlobalKey<TitleComposeFieldState> _titleFieldKey =
      GlobalKey<TitleComposeFieldState>();

  /// Current step. Always starts on the sections picker (step 1).
  _ComposeStep _step = _ComposeStep.sections;

  /// True when this compose was opened by the Help & Feedback command. Drives
  /// the feedback-specific editor placeholder. Set by [_applyFeedbackMode] /
  /// [_applyTarget]'s `feedback` flag and cleared by [_resetToFreshStart] or
  /// when the user picks a different target.
  bool _feedbackMode = false;

  /// The target chosen in step 1, retained so submit can record it.
  ComposeTarget? _selectedTarget;

  /// The link held in the step-1 picker (pasted or shared URL + metadata).
  /// Non-null ⇒ link mode: the filter input shows a chip and the sections are
  /// Private notes + link-supporting Channels. Added to the draft note only
  /// when a destination is chosen (see [_applyTarget]).
  LinkChipData? _pendingLink;

  /// Previous filter text, tracked so [_maybeEnterLinkModeFromField] can tell a
  /// paste (multi-char jump) from char-by-char typing — only a pasted/shared URL
  /// enters link mode, never an incrementally typed one.
  String _lastFilterText = '';

  /// The recipient chosen in step 1 (a people pill), retained to drive the
  /// step-2 connection picker and the compose-step back-nav. Null on
  /// twist/channel/private-note paths (which skip step 2).
  ComposePeopleEntry? _selectedRecipient;

  /// The step-1 filter text stashed when advancing to step 2 (which clears the
  /// shared field for "Select a connection"); restored on back.
  String _stashedSectionsQuery = '';

  /// Focuses ordered for the focus picker by recency of threads filed with the
  /// chosen target's roster (MRU-top is the auto-suggested focus). Empty until
  /// a target is applied. See [_suggestFocusForTarget].
  List<Priority> _focusSuggestionOrder = const [];

  // Controllers for the inline step-1 picker. Recreated for the step-2 modal
  // re-open so the two mounts don't share scroll/highlight state.
  final ScrollController _pickerScrollController = ScrollController();

  /// Focus node for the inline step-1 search field. Owned here (not by the
  /// picker) so [_resetToFreshStart] can re-focus the filter when the
  /// already-mounted page is reset to step 1 — AutoRoute reuses the same
  /// [ComposeSectionsView] instance, so its `autofocus` won't fire again.
  final FocusNode _pickerSearchFocusNode = FocusNode(
    debugLabel: 'NewThread-target-picker-search',
  );

  /// Search-text controller for the inline step-1 picker. Owned here (not by
  /// the picker) so the typed filter survives the step-1 → step-2 → step-1
  /// round-trip (the page stashes it on advance and restores it on a "go back"
  /// — see [_pickRecipient] / [_returnToSectionsStep]). Cleared by
  /// [_resetToFreshStart] so a brand-new compose starts with an empty filter.
  final TextEditingController _pickerSearchController = TextEditingController();

  // ---- Active/inactive panel styling ------------------------------------
  //
  // To reduce how much the panel catches the eye when it isn't in use, the
  // whole body fades between an "active" (full strength) and "inactive" (muted
  // by one step — see [kNewThreadInactiveOpacity]) appearance. The state is
  // computed from the inputs below into [_active]; a [ValueListenableBuilder]
  // drives only the opacity layer so toggling never rebuilds the (expensive)
  // editor subtree.

  /// Drives the body's [AnimatedOpacity]. Recomputed by [_recomputeActive]
  /// whenever an input changes; never via `setState` (which would rebuild the
  /// NoteEditor and flicker). Starts inactive — the autofocus the page grabs on
  /// open is "by design" and must NOT light the panel.
  final ValueNotifier<bool> _active = ValueNotifier<bool>(false);

  /// Whether the pointer is currently over the panel.
  bool _mouseInside = false;

  /// Whether any descendant holds keyboard focus. NOT an activation input —
  /// focus alone (e.g. the on-open autofocus) must not light the panel, and
  /// focus-LOSS must not deactivate it (the app churns focus internally — e.g.
  /// [_focusPickerSearch] drops then re-grabs focus on reset — which would wipe
  /// a just-applied engagement). Used only to gate [_onHardwareKey].
  bool _pageFocused = false;

  /// True while the panel is "engaged": the user navigated/typed within the
  /// focused panel (a non-modifier, non-shortcut key), OR an explicit New-thread
  /// command opened/reset it (see [_activateOnOpen] / [_onResetRequested]).
  /// Cleared on pointer-exit or an Escape on the empty step-1 filter.
  bool _engaged = false;

  /// True when the user pressed Escape on the empty step-1 filter to dismiss the
  /// panel. Forces inactive even while the pointer is still over the panel
  /// ("press Esc again to dismiss"). Cleared the moment the pointer crosses the
  /// panel boundary again, or the user types / re-engages.
  bool _dismissed = false;

  /// Whether this page is in single-panel mode. Single-panel is always active
  /// (no dimming on mobile / narrow layouts). Assigned from `!multiPanel` in
  /// [build] and OR-ed into the opacity at render time — deliberately NOT part
  /// of [_active], so toggling the layout can never strand a stale active value.
  bool _singlePanel = false;

  /// Set by the [NewThread] command (button / ⌘N) just before it navigates, so
  /// a fresh mount can tell it was opened by an explicit user command — and
  /// should start active — versus the passive default mount (root panel), which
  /// stays inactive. Consumed once: by the mounting page's [initState], or by
  /// [_onResetRequested] when a live page handles the command instead.
  static bool _activateOnOpen = false;

  /// Called by the [NewThread] command right before it routes to the page.
  static void activateOnOpen() => _activateOnOpen = true;

  /// Recomputes [_active] from the current inputs. Updates only the notifier —
  /// never `setState` — so the body subtree isn't rebuilt.
  void _recomputeActive() {
    if (_dismissed) {
      _active.value = false;
      return;
    }
    _active.value =
        _mouseInside ||
        _engaged ||
        _pickerSearchController.text.trim().isNotEmpty;
  }

  /// Publishes the current step's back handler to the shared
  /// [ThreadHeaderNotifier] so [UnifiedHeader] can render the new-thread back
  /// chevron in the (single-panel) header strip — aligned with the
  /// PriorityPage / ThreadPage backs — instead of inside the page body.
  ///
  ///   * sections (step 1) → null (no back; the bottom-nav tab is the exit)
  ///   * connection (step 2) → [_returnToSectionsStep]
  ///   * compose (step 3) → [_backFromCompose] (→ connection if a recipient was
  ///     picked, else sections)
  ///
  /// Call after every `_step` mutation. Cleared to null on dispose / leaving
  /// `/new` via [ThreadHeaderNotifier.unregister].
  void _publishHeaderBack() {
    final notifier = _headerNotifier;
    if (notifier == null) return;
    switch (_step) {
      case _ComposeStep.sections:
        notifier.setNewThreadBack(null);
      case _ComposeStep.connection:
        notifier.setNewThreadBack(_returnToSectionsStep);
      case _ComposeStep.compose:
        notifier.setNewThreadBack(_backFromCompose);
    }
  }

  /// Filter-controller listener: the filter text contributes to [_active] (any
  /// text keeps the panel active), so recompute whenever it changes. Typing also
  /// lifts an Escape-dismiss.
  void _onFilterChanged() {
    if (_pickerSearchController.text.trim().isNotEmpty) _dismissed = false;
    _recomputeActive();
    _maybeEnterLinkModeFromField();
  }

  /// When the filter text gains an http(s) URL via paste (a multi-character
  /// jump — not char-by-char typing), switch to link mode: stash the URL as the
  /// pending link and clear the field so it doesn't double as a filter. No-op
  /// when already in link mode. The share-intent path enters link mode directly
  /// via [_enterLinkMode], bypassing this paste gate.
  void _maybeEnterLinkModeFromField() {
    final text = _pickerSearchController.text;
    final prev = _lastFilterText;
    _lastFilterText = text;
    if (_pendingLink != null) return;
    // Only a paste/share (a multi-character jump) enters link mode — typing a
    // URL one character at a time leaves it as ordinary filter text.
    if (text.length - prev.length < 2) return;
    final url = extractHttpUrl(text);
    if (url == null) return;
    _enterLinkMode(url);
    _pickerSearchController.clear();
  }

  /// Enters link mode for [url] and kicks off a metadata fetch.
  void _enterLinkMode(String url) {
    setState(() => _pendingLink = LinkChipData(url: url));
    unawaited(_resolvePendingLinkMetadata(url));
  }

  /// Clears the pending link (chip ✕) and returns to the text filter input.
  void _clearPendingLink() {
    setState(() => _pendingLink = null);
    _focusPickerSearch(_ComposeStep.sections);
  }

  /// Global key handler. Two jobs, both gated on the panel being focused:
  ///
  /// 1. **Dismiss**: Escape on the empty step-1 filter disengages the panel
  ///    (it dims unless the pointer is still over it). The field's own Escape
  ///    first clears any text, so this fires on the *second* Escape — "press
  ///    Esc again to dismiss". Never consumes the event (other Esc handlers run).
  /// 2. **Engage**: any other real key press (not a modifier, not a ⌘/Ctrl/Alt
  ///    shortcut like ⌘N) counts as in-panel keyboard navigation and engages.
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!_pageFocused) return false;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_active.value &&
          _step == _ComposeStep.sections &&
          _pickerSearchController.text.trim().isEmpty) {
        _engaged = false;
        _dismissed = true;
        _recomputeActive();
      }
      return false;
    }

    if (_engaged) return false;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed) {
      return false;
    }
    if (_modifierKeys.contains(event.logicalKey)) return false;
    _engaged = true;
    _dismissed = false;
    _recomputeActive();
    return false;
  }

  static final Set<LogicalKeyboardKey> _modifierKeys = {
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };

  // Save reference to provider to avoid looking it up in dispose()
  PriorityShortcutsProviderState? _provider;
  ThreadHeaderNotifier? _headerNotifier;
  // Cached so callbacks triggered during deactivate() (e.g. NoteEditor
  // saving its draft) don't call context.read once ancestors are detached.
  PriorityBloc? _priorityBloc;
  bool _hasAppliedQueryParams = false;

  /// All available create-targets for this user, loaded once on mount and
  /// rerun when the priority changes (so MRU rerank reflects the new
  /// priority).
  List<CreateTarget> _allConnectionTargets = const [];

  /// Whether the user belongs to ≥1 team, plus team display names by id.
  /// Loaded once on mount ([_loadTeams]); drives the connection field's
  /// "Plot" + team scope ([_plotChoiceForDraft]).
  bool _hasTeams = false;
  Map<BigInt, String> _teamNames = const {};

  // Selected twist for chat mode
  TwistInstance? _selectedTwist;

  /// True once the user has added at least one contact (including groups /
  /// invite-emails) during this compose session. Keeps the Chat placeholder
  /// and "Send" label active even if the user later removes all contacts.
  bool _hadContactsThisSession = false;

  void _markContactsAdded() {
    if (!_hadContactsThisSession) {
      setState(() => _hadContactsThisSession = true);
    }
  }

  /// The [resetRequest] value seen on the last reset. Bumps past this trigger
  /// a fresh-start reset; the initial assignment in [initState] ignores the
  /// bump that the [NewThread] command fired to navigate here (a fresh mount
  /// is already clean).
  late int _lastResetSeen = NewThreadPageState.resetRequest.value;

  /// The [feedbackRequest] value seen on the last feedback entry, mirroring
  /// [_lastResetSeen]. A fresh mount ignores the bump the [HelpAndFeedback]
  /// command fired to navigate here (it reacts to the `feedback` route param
  /// instead); only a later bump against this live page re-enters feedback.
  late int _lastFeedbackSeen = NewThreadPageState.feedbackRequest.value;

  @override
  void initState() {
    super.initState();
    NewThreadPageState.resetRequest.addListener(_onResetRequested);
    NewThreadPageState.feedbackRequest.addListener(_onFeedbackRequested);
    _pickerSearchController.addListener(_onFilterChanged);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    // Start active only when an explicit New-thread command opened this fresh
    // mount; a passive default mount (root panel) stays inactive. Consume the
    // one-shot flag so it can't leak into a later passive mount.
    if (NewThreadPageState._activateOnOpen) {
      NewThreadPageState._activateOnOpen = false;
      _engaged = true;
      _recomputeActive();
    }
    // Scene S5: pre-seed the people-picker search field so the picker filters
    // to the desired contact on first render.
    final scenePickerQuery = Scenes.pickerQuery;
    if (Scenes.active && scenePickerQuery != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _pickerSearchController.text = scenePickerQuery;
      });
    }
  }

  /// Reacts to a [HelpAndFeedback] re-invocation against this already-mounted
  /// page: reconfigures it for feedback (see [_applyFeedbackMode]).
  void _onFeedbackRequested() {
    if (!mounted) return;
    if (NewThreadPageState.feedbackRequest.value == _lastFeedbackSeen) return;
    _lastFeedbackSeen = NewThreadPageState.feedbackRequest.value;
    unawaited(_applyFeedbackMode());
  }

  /// Reacts to a [NewThread] re-invocation against this already-mounted page:
  /// resets to step 1 with a fresh draft (see [_resetToFreshStart]).
  void _onResetRequested() {
    if (!mounted) return;
    if (NewThreadPageState.resetRequest.value == _lastResetSeen) return;
    _lastResetSeen = NewThreadPageState.resetRequest.value;
    // An explicit New-thread command re-invoked this live page → engage it
    // (mirrors a command-driven fresh mount). requestReset() is only ever called
    // by that command, so reaching here always means an explicit invocation.
    // Consume the open flag so it can't leak to a later passive mount.
    NewThreadPageState._activateOnOpen = false;
    _engaged = true;
    _dismissed = false;
    _recomputeActive();
    _resetToFreshStart();
  }

  /// Returns the page to step 1 (target picker) with a brand-new draft,
  /// discarding any connection / roster / focus / title chosen in an
  /// in-progress step-2 session. Used when the user invokes "New thread"
  /// while a [NewThreadPage] is already live (AutoRoute reuses it rather than
  /// mounting a fresh State).
  void _resetToFreshStart() {
    final bloc = _priorityBloc ?? context.read<PriorityBloc>();

    // Clear the draft fully: schedule/title (resetDraft's scope) plus the
    // connection action, external link action, roster, team scope, and twist
    // icon that step 2 may have applied. Reuse the existing draft id to avoid
    // stranding archived drafts.
    final draft = bloc.state.draft;
    final note = bloc.state.draftNote;
    final clearedActions = (note.actions ?? const <UserAction>[])
        .where((a) => a is! CreateLinkUserAction && a is! ExternalUserAction)
        .toList();
    final clearedDraft = draft.copyWith(
      title: const Value(null),
      at: const Value(null),
      on: const Value(null),
      duration: const Value(null),
      preview: const Value(null),
      contacts: const Value(null),
      groups: const Value(null),
      inviteEmails: const Value(null),
      teamId: const Value(null),
      icon: const Value(null),
      topicId: const Value(null),
    );
    unawaited(
      bloc.updateDraft(
        clearedDraft,
        note: note.copyWith(actions: clearedActions),
      ),
    );

    // Empty the (page-owned) filter so a fresh compose starts unfiltered.
    _pickerSearchController.clear();

    setState(() {
      _step = _ComposeStep.sections;
      _selectedTarget = null;
      _pendingLink = null;
      _selectedRecipient = null;
      _stashedSectionsQuery = '';
      _selectedTwist = null;
      _hadContactsThisSession = false;
      _focusSuggestionOrder = const [];
      _feedbackMode = false;
    });
    // Reset returns to step 1 — clear the header back affordance.
    _publishHeaderBack();

    // Re-focus the inline filter after the rebuild. AutoRoute reuses the same
    // ComposeSectionsView instance, so its `autofocus` won't re-fire on this
    // reset — claim focus explicitly. [_focusPickerSearch] drops focus first so
    // the request is a real change even when the (page-owned, step-shared) node
    // already held focus; otherwise the field wouldn't re-open its text-input
    // connection and would need an OS focus round-trip (alt-tab) to engage.
    _focusPickerSearch(_ComposeStep.sections);

    // Re-seed the target picker's base list so step 1 shows its rows (focuses,
    // people, twists, connectors) immediately (mirrors the fresh-mount path in
    // _initializeDraft).
    unawaited(
      context.read<ComposeTargetsBloc>().refresh().catchError((
        Object e,
        StackTrace s,
      ) {
        Tracker.captureException(e, s);
      }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Mark this as the live new-thread page so the search-close focus-restore
    // path can find it and (on step 1) focus the inline filter. AutoRoute keeps
    // a single NewThreadPage mounted, so the last one through here wins.
    NewThreadPageState._live = this;

    // Save the provider reference
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    _priorityBloc = context.read<PriorityBloc>();
    // Register with ThreadHeaderNotifier so unified header knows NewThreadPage is visible
    _headerNotifier = ThreadHeaderNotifierProvider.read(context);
    // We've arrived — clear the navigation-intent flag set by callers
    // like the bottom-nav "New" button (priorities_shell._openNewThread).
    if (ThreadHeaderNotifier.pendingNewThreadIntent.value) {
      ThreadHeaderNotifier.pendingNewThreadIntent.value = false;
    }
    // Prefer middle panel on resize while NewThreadPage is visible
    context.read<LayoutBloc>().preferMiddle = true;
    // Register ThreadEditor with the focus coordination provider
    // Both registrations deferred to avoid notifyListeners() during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _headerNotifier?.register(
        onSearchChanged: (_) {},
        // Closing the header search bar restores focus to the note editor on
        // step 2 (via the editorFocusCallback / ClearItemFocusIntent path). On
        // step 1 the editor isn't mounted — the inline target picker is — so
        // hand focus to its filter input instead. focusFilter() no-ops off step
        // 1 and on touch-only platforms, so the regular note-editor behavior is
        // unchanged everywhere else.
        onSearchClosed: NewThreadPageState.focusFilter,
        tags: const [],
        filter: const [],
        isNewThread: true,
      );
      // Seed the header back handler for the current step (sections → none).
      _publishHeaderBack();
      _provider?.registerActivityPanel(
        // This callback is the new-thread page's "restore editor focus" hook,
        // invoked by the search-close / Escape focus-restore path
        // (priority.dart's ClearItemFocusIntent). On step 1 the note editor
        // isn't mounted — the inline target picker is — so focus its filter
        // input instead of the (absent) editor. focusFilter() itself no-ops
        // off step 1 and on touch-only platforms, so step 2 keeps focusing the
        // editor as before.
        editorFocusCallback: () {
          if (NewThreadPageState.isOnStep1) {
            NewThreadPageState.focusFilter();
            return;
          }
          _threadEditorKey.currentState?.focus();
        },
      );
    });

    // Apply query parameters to draft
    if (!_hasAppliedQueryParams) {
      _hasAppliedQueryParams = true;
      _initializeDraft();
    }
  }

  /// Sequences query parameter application and post-load setup.
  /// Async because _applyQueryParametersToDraft awaits DB lookups.
  Future<void> _initializeDraft() async {
    await _applyQueryParametersToDraft();
    if (!mounted) return;

    // Populate the step-1 target picker (MRU-ordered base list). Fire-and-
    // forget — the picker reads the bloc's state reactively, and a stale
    // empty list just shows briefly until refresh resolves.
    unawaited(
      context.read<ComposeTargetsBloc>().refresh().catchError((
        Object e,
        StackTrace s,
      ) {
        Tracker.captureException(e, s);
      }),
    );

    // Load available connection create-targets so the step-2 Connection field
    // can resolve the active CreateLinkUserAction back to a label.
    await _loadConnections();
    if (!mounted) return;

    // Load team scope so the connection field can show "Plot" with the team.
    // Fire-and-forget — the field reads `_hasTeams`/`_teamNames` reactively.
    unawaited(_loadTeams());

    // Help & Feedback (fresh mount): configure the page for a Plot-Team chat
    // filed under Inbox. A reused live page is handled via [feedbackRequest]
    // instead (this path won't re-run — see [_hasAppliedQueryParams]).
    if (widget.feedback ?? false) {
      await _applyFeedbackMode();
    }
  }

  /// Configures the page for the Help & Feedback command: a Plot **Chat**
  /// addressed to the Plot Team group, filed under the user's **Inbox**, with
  /// the note editor focused and a feedback-specific placeholder. Replaces the
  /// connection / roster / focus / title of any in-progress compose, since the
  /// command can land on a live AutoRoute-reused page mid-edit.
  Future<void> _applyFeedbackMode() async {
    final bloc = _priorityBloc ?? context.read<PriorityBloc>();

    // Resolve the Plot Team group (offline-capable) and warm the group cache so
    // it renders as a recipient chip in step 2.
    final groupId = await Group.feedbackTargetId();
    if (!mounted) return;
    if (groupId != null) {
      await Group.getOne(groupId);
      if (!mounted) return;
    }

    final teams = await TeamUser.getActive();
    if (!mounted) return;

    // Clear any in-progress roster/title so a reused page starts clean — the
    // chat target below leaves contacts untouched when it carries none.
    final draft = bloc.state.draft;
    await bloc.updateDraft(
      draft.copyWith(
        contacts: const Value(null),
        inviteEmails: const Value(null),
        title: const Value(null),
      ),
    );
    if (!mounted) return;

    // Build a Personal Plot Chat target carrying the Plot Team group roster and
    // apply it through the normal target path (chat mode, roster, step-2
    // transition, editor focus). Feedback mode skips the MRU focus suggestion so
    // the Inbox focus set below survives.
    final target = ComposeTarget.chat(
      teamId: null,
      hasTeams: teams.isNotEmpty,
      contactDetail: 'Plot Team',
      groups: groupId != null ? [groupId] : const [],
    );
    await _applyTarget(target, feedback: true);
    if (!mounted) return;

    // Force the Inbox (root) focus, overriding any remembered default priority.
    // Done directly (not via [_switchToPriority]) so the remembered new-thread
    // default isn't repointed at Inbox for the user's next compose.
    final root = context.read<PrioritiesBloc>().state.root;
    if (root != null && root.id != bloc.state.draft.priority.id) {
      await bloc.updateDraft(bloc.state.draft.copyWith(priority: root));
    }
  }

  Future<void> _loadConnections() async {
    try {
      final targets = await loadCreateTargets();
      if (!mounted) return;
      setState(() {
        _allConnectionTargets = targets;
      });
    } catch (e, t) {
      log.warning('[NewThreadPage._loadConnections] failed', e, t);
      Tracker.captureException(e, t);
    }
  }

  /// Loads the user's active team memberships so the connection field can show
  /// the team scope beside "Plot" (only when the user belongs to ≥1 team).
  Future<void> _loadTeams() async {
    try {
      final teams = await TeamUser.getActive();
      if (!mounted) return;
      setState(() {
        _hasTeams = teams.isNotEmpty;
        _teamNames = {for (final t in teams) t.teamId: t.teamName};
      });
    } catch (e, t) {
      log.warning('[NewThreadPage._loadTeams] failed', e, t);
      Tracker.captureException(e, t);
    }
  }

  Future<void> _applyQueryParametersToDraft() async {
    final bloc = context.read<PriorityBloc>();

    // Parse query parameters
    DateTime? queryStartTime;
    DateTime? queryEndTime;
    Priority? queryPriority;

    if (widget.startTime != null) {
      try {
        queryStartTime = DateTime.parse(widget.startTime!);
      } catch (e) {
        log.warning('[NewThreadPage] Failed to parse startTime', e);
      }
    }

    if (widget.endTime != null) {
      try {
        queryEndTime = DateTime.parse(widget.endTime!);
      } catch (e) {
        log.warning('[NewThreadPage] Failed to parse endTime', e);
      }
    }

    // If startTime is provided but endTime is not, calculate from duration
    if (queryStartTime != null && queryEndTime == null) {
      final durationMinutes = widget.duration ?? 60; // Default to 1 hour
      queryEndTime = queryStartTime.add(Duration(minutes: durationMinutes));
    }

    if (widget.priorityId != null) {
      try {
        final priorityId = Uuid.fromShortString(widget.priorityId!);
        queryPriority = await Priority.getOne(priorityId);
      } catch (e) {
        log.warning('[NewThreadPage] Failed to parse priorityId', e);
      }
    }

    // Apply remembered default priority if no query priority was provided
    if (queryPriority == null && bloc.newThreadDefaultPriority != null) {
      final remembered = bloc.newThreadDefaultPriority!;
      if (remembered.id != bloc.state.draft.priority.id) {
        queryPriority = remembered;
      }
    }

    if (!mounted) return;

    // Apply to draft if any query parameters were provided
    // Re-read bloc.state.draft after awaits to avoid overwriting concurrent changes
    if (queryStartTime != null || queryPriority != null) {
      Thread updatedDraft;
      if (queryStartTime != null && queryEndTime != null) {
        // StartTime takes precedence - create a scheduled activity
        updatedDraft = bloc.state.draft.copyWith(
          at: Value(DateTimeRange(queryStartTime, queryEndTime)),
          priority: queryPriority ?? bloc.state.draft.priority,
          draft: true,
        );
        await bloc.updateDraft(updatedDraft);
      } else if (queryPriority != null) {
        updatedDraft = bloc.state.draft.copyWith(
          priority: queryPriority,
          draft: true,
        );
        await bloc.updateDraft(updatedDraft);
      }
    }

    // Help & Feedback is configured after the query-param pass completes (see
    // [_applyFeedbackMode], dispatched from [_initializeDraft]); it needs the
    // chat target + step-2 transition, not just a group pre-share.

    // Share intent: enter link mode with the shared URL prefilled. The link is
    // added to the note only when the user picks a destination (see
    // [_applyTarget]); until then it lives as the pending link / chip.
    if (widget.sharedUrl != null && mounted) {
      _enterLinkMode(widget.sharedUrl!);
    }
  }

  /// Fetches `<title>` + favicon for [url] and folds them into [_pendingLink]
  /// (so the chip shows them). No-op if link mode was cleared or changed.
  Future<void> _resolvePendingLinkMetadata(String url) async {
    try {
      final meta = await fetchUrlMetadata(url);
      if (!mounted) return;
      final current = _pendingLink;
      if (current == null || current.url != url) return;
      if (meta.title == null && meta.favicon == null) return;
      // The chip is display-only (no user title edit), so overwriting the
      // placeholder URL/title with fetched metadata is always correct here.
      setState(() {
        _pendingLink = LinkChipData(
          url: url,
          title: meta.title ?? current.title,
          favicon: meta.favicon ?? current.favicon,
        );
      });
    } catch (e, s) {
      Tracker.captureException(e, s);
    }
  }

  @override
  void dispose() {
    // Clear the live-page pointer if it still points at us (a newer page may
    // have already claimed it in didChangeDependencies).
    if (identical(NewThreadPageState._live, this)) {
      NewThreadPageState._live = null;
    }
    NewThreadPageState.resetRequest.removeListener(_onResetRequested);
    NewThreadPageState.feedbackRequest.removeListener(_onFeedbackRequested);
    // Unregister from the focus coordination provider using saved reference
    _provider?.unregisterActivityPanel();
    // Unregister from thread header notifier
    _headerNotifier?.unregister();
    // Clear middle panel preference when leaving NewThreadPage
    LayoutBloc.instance?.preferMiddle = false;
    _pickerScrollController.dispose();
    _pickerSearchFocusNode.dispose();
    _pickerSearchController.removeListener(_onFilterChanged);
    _pickerSearchController.dispose();
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _active.dispose();
    super.dispose();
  }

  Future<void> _selectPriority(
    BuildContext context,
    PriorityState state,
  ) async {
    final result = await SelectModal.open<PriorityChoice>(
      context,
      items: (search) async {
        final priorities = await Priority.get(order: PriorityOrder.nested);
        final query = search?.trim().toLowerCase() ?? '';
        // Partition out the root (Inbox), which `get` returns alongside the
        // focuses, so it's pinned to the bottom as a branded "Inbox" row
        // instead of appearing inline as a plain focus.
        final inboxId = Priority.defaultInbox(priorities)?.id;
        Priority? root;
        final focuses = <Priority>[];
        for (final p in priorities) {
          if (p.id == inboxId) {
            root = p;
          } else if (query.isEmpty || p.matchesSearch(search ?? '')) {
            focuses.add(p);
          }
        }
        // Order focuses by the target's MRU suggestion (most-recent focus
        // filed-with-this-roster first), then the remaining focuses in their
        // nested order. Auto-organize is gone — the flow always picks a
        // concrete focus (see _suggestFocusForTarget).
        final ranked = _rankFocusesBySuggestion(focuses);
        return [
          SelectGroup<PriorityChoice>(
            title: null,
            items: [
              ...ranked.map(PickedPriorityChoice.new),
              if (root != null &&
                  (query.isEmpty || root.matchesSearch(search ?? '')))
                PickedPriorityChoice(root),
            ],
          ),
        ];
      },
      itemBuilder: (choice, _) => switch (choice) {
        // FocusLabel brands the root focus as "Inbox" on its own, so the
        // picked-priority arm covers the Inbox row too.
        PickedPriorityChoice(:final priority) => ListTile(
          body: FocusLabel(priority: priority),
        ),
        // Auto-organize is no longer offered; the arm is unreachable but the
        // switch must stay exhaustive over the sealed PriorityChoice.
        AutoOrganizeChoice() => ListTile(body: const SizedBox.shrink()),
      },
      selectedValue: PickedPriorityChoice(state.draft.priority),
      prompt: 'Select focus',
      onAdd: (ctx) => createPriorityInline(
        ctx,
        parent: state.draft.priority,
      ).then((p) => p == null ? null : PickedPriorityChoice(p)),
    );
    if (!result.present) return;
    final picked = result.value;
    if (!mounted) return;
    if (picked is PickedPriorityChoice) {
      await _switchToPriority(picked.priority);
      if (!mounted) return;
      // A mouse tap on the focus field moved keyboard focus to the field
      // before the picker opened (ComposeSelectField._handleTap), so the
      // navigator restores focus to the field — not the editor — when the
      // picker closes, stranding the caret. Return focus to the composer so
      // the user can keep typing. Post-frame so it lands after the picker
      // route's own focus restoration; idempotent for the keyboard-shortcut
      // path, where the editor already holds focus.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _threadEditorKey.currentState?.focus();
      });
    }
  }

  /// Orders [focuses] by the target's focus suggestion: any focus present in
  /// [_focusSuggestionOrder] first (in that order), then the rest preserving
  /// their input (nested) order.
  List<Priority> _rankFocusesBySuggestion(List<Priority> focuses) {
    if (_focusSuggestionOrder.isEmpty) return focuses;
    final order = <PriorityId, int>{};
    for (var i = 0; i < _focusSuggestionOrder.length; i++) {
      order[_focusSuggestionOrder[i].id] = i;
    }
    final ranked = focuses.toList()
      ..sort((a, b) {
        final ai = order[a.id] ?? 1 << 30;
        final bi = order[b.id] ?? 1 << 30;
        return ai.compareTo(bi);
      });
    return ranked;
  }

  Future<void> _switchToPriority(Priority priority) async {
    final bloc = context.read<PriorityBloc>();
    final draft = bloc.state.draft;
    setState(() {
      ThreadsBase.autoFileIds.remove(draft.id.toString());
    });
    if (priority.id != draft.priority.id) {
      // Swap the draft's focus only. The target picker (step 1) drives the
      // roster now, so switching focus must NOT union per-focus default
      // contacts/groups onto the draft (the old _applyChainDefaults merge,
      // removed in the two-step redesign).
      await bloc.updateDraft(draft.copyWith(priority: priority));
    }
    bloc.setNewThreadDefaultPriority(priority);
  }

  /// Routes a ConnectionChoice from the modal/dropdown into the draft.
  /// - Plot thread: clear CreateLinkUserAction and twist. Plot threads no
  ///   longer carry a note/task/chat mode — the To-do tag is set via the
  ///   editor's bottom-bar toggle, and shared-vs-private is derived from
  ///   whether recipients are present.
  /// - CreateTarget: set CreateLinkUserAction; clear any selected twist.
  /// - Twist: clear CreateLinkUserAction; set the twist (icon + selected state).
  Future<void> _applyConnectionChoice(ConnectionChoice choice) async {
    final bloc = _priorityBloc;
    if (bloc == null) return;
    final note = bloc.state.draftNote;
    final actions = List<UserAction>.from(note.actions ?? const []);
    actions.removeWhere((a) => a is CreateLinkUserAction);

    if (choice is TwistConnectionChoice) {
      // Drop any active CreateLinkUserAction, then apply the twist via the
      // existing _selectTwist path (sets thread.icon = 'twist:N').
      await bloc.updateDraft(
        bloc.state.draft,
        note: note.copyWith(actions: actions),
      );
      if (!mounted) return;
      _selectTwist(choice.twist);
      return;
    }

    // Plot thread / CreateTarget: clear any selected twist.
    if (_selectedTwist != null) {
      setState(() => _selectedTwist = null);
      final draft = bloc.state.draft;
      // Restore default icon when leaving a twist selection.
      final cleared = draft.copyWith(icon: const Value(null));
      bloc.updateDraftLocal(cleared);
    }

    final action = choice.toUserAction();
    if (action != null) actions.add(action);
    // Plot threads no longer carry a note/chat mode — shared-vs-private is
    // derived from whether recipients are present (see [_computeEditorHint] /
    // [_computeSendLabel]); a rostered target marks contacts via
    // [_markContactsAdded] in [_applyTarget].
    final Note nextNote = note.copyWith(actions: actions);
    // Pass the list directly (even when empty) — Note.copyWith treats a
    // null `actions` arg as "keep existing", so the prior CreateLinkUserAction
    // would survive when the user picks a Plot thread.
    await bloc.updateDraft(bloc.state.draft, note: nextNote);
  }

  /// Applies a [ComposeTarget] chosen in the picker to the draft and advances
  /// to step 2 (compose). Sets the draft team, the connection (via the
  /// existing [_applyConnectionChoice] / [_selectTwist] paths), and the
  /// target's pre-filled roster (contacts/groups). Then suggests an MRU focus
  /// and focuses the editor.
  Future<void> _applyTarget(
    ComposeTarget target, {
    bool feedback = false,
  }) async {
    final bloc = _priorityBloc;
    if (bloc == null) return;

    // Advance to compose immediately, before any of the store-backed work
    // below. The compose surface reads the draft reactively, so the connection,
    // roster, and focus applied afterward land a frame or two later without
    // blocking the screen switch. Flipping the step first is also what stops the
    // step-1 picker from visibly twitching: each draft mutation below emits a
    // PriorityBloc state, and while step 1 was still mounted every emit rebuilt
    // it — and because ComposeSectionsView hands PillGrid a freshly-built
    // (identity-distinct) section list on each rebuild, PillGrid reset its
    // keyboard highlight to the first row every time, so the selection snapped
    // back to the top a couple of times before the switch finally happened.
    setState(() {
      _selectedTarget = target;
      // Picking any target through the normal flow leaves feedback mode; the
      // Help & Feedback path passes feedback: true to keep its placeholder.
      _feedbackMode = feedback;
      _step = _ComposeStep.compose;
    });
    _publishHeaderBack();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _threadEditorKey.currentState?.focus();
    });

    // 1. Connection: reuse the established apply path so a connector target's
    //    CreateLinkUserAction (or a twist selection) is attached identically to
    //    the legacy picker. The Connection field resolves the action back to a
    //    label from the create-targets already loaded on mount, so refresh them
    //    in the background (never blocking the transition) instead of awaiting a
    //    full re-enumeration of every enabled channel on every pick — that
    //    redundant scan was the bulk of the switch delay. The connection apply
    //    itself emits its draft change synchronously, so the compose surface
    //    shows the right connection on its first build (no flash).
    unawaited(_loadConnections());
    await _applyConnectionChoice(target.toConnectionChoice());
    if (!mounted) return;

    // 2. Team + roster: set the draft's team scope and pre-fill the target's
    //    contacts/groups (e.g. "Chat with Greg") and any pending invite emails
    //    (e.g. "Chat with foo@bar.com" for a brand-new address). Read the latest
    //    draft after the connection apply's await so we don't clobber its
    //    note/action edit.
    final draft = bloc.state.draft;
    // Pending invite emails count as a roster: a Chat-with-email is a shared
    // thread even before the invitee resolves to a contact.
    final hasRoster =
        target.contacts.isNotEmpty ||
        target.groups.isNotEmpty ||
        target.inviteEmails.isNotEmpty;
    // A no-roster target (a Note, or a connector with SharingModel.none such as
    // Google Tasks) must explicitly CLEAR the draft's roster rather than leave
    // it untouched: switching from "Chat with Greg" to a Note would otherwise
    // keep Greg attached-but-hidden and submit the Note as shared. Same
    // no-roster predicate as [_shouldShowContacts]. For roster-bearing targets,
    // pre-fill the roster (or leave it absent when the template carries none,
    // e.g. a fresh channel target the user will address later).
    final noRoster = _targetHasNoRoster(target);
    final updated = draft.copyWith(
      teamId: Value(target.teamId),
      contacts: noRoster
          ? const Value(null)
          : target.contacts.isEmpty
          ? const Value.absent()
          : Value(target.contacts),
      groups: noRoster
          ? const Value(null)
          : target.groups.isEmpty
          ? const Value.absent()
          : Value(target.groups),
      // Clear invite emails when switching to a no-roster target; otherwise
      // carry the target's (or leave absent when it has none, so a prior
      // address typed this session survives a roster-bearing reselect).
      inviteEmails: noRoster
          ? const Value(null)
          : target.inviteEmails.isEmpty
          ? const Value.absent()
          : Value(target.inviteEmails),
      // Topic targets file the thread into a Plot topic (sets thread.topic_id);
      // every other target clears it so switching away from a topic doesn't
      // strand the previous filing.
      topicId: Value(target.topicId),
    );
    await bloc.updateDraft(updated);
    if (!mounted) return;
    if (hasRoster) _markContactsAdded();

    // Link mode: attach the pending link to the draft NOTE (never the thread),
    // deriving the thread title/icon from it when the user hasn't set one.
    final link = _pendingLink;
    if (link != null) {
      final latest = bloc.state.draft;
      final note = appendExternalLink(
        bloc.state.draftNote,
        url: link.url,
        title: link.title,
        favicon: link.favicon,
      );
      final hasUserTitle = latest.title?.isNotEmpty ?? false;
      final hasUserIcon = latest.icon?.isNotEmpty ?? false;
      final titledDraft = latest.copyWith(
        title: hasUserTitle ? const Value.absent() : Value(link.display),
        icon: hasUserIcon
            ? const Value.absent()
            : Value(link.favicon ?? 'link'),
      );
      await bloc.updateDraft(titledDraft, note: note);
      if (!mounted) return;
    }

    // 3. Suggest a concrete focus for this target's roster (MRU-top first).
    //    The step already flipped to compose above; this resolves
    //    asynchronously and updates the focus field / picker order reactively
    //    when it lands — no need to block the transition on a DB scan. Skipped
    //    in feedback mode: Help & Feedback forces the Inbox focus (applied by
    //    [_applyFeedbackMode] after this returns), so an MRU suggestion would
    //    only be overwritten.
    if (!feedback) await _suggestFocusForTarget(target);
  }

  /// Hands keyboard focus to the shared picker search field after a step
  /// transition or (re)entry, on the next frame.
  ///
  /// The picker reuses one page-owned focus node ([_pickerSearchFocusNode])
  /// across every step. On re-entry paths (the New-thread button reset, Esc
  /// back to step 1) that node can still be the primary focus, so a plain
  /// `requestFocus()` is a no-op (no focus *change*) and the freshly shown
  /// field never re-opens its text-input connection — it shows no caret until
  /// an OS focus round-trip (alt-tab). Dropping focus first guarantees the
  /// request below is a real lose→gain that re-opens the connection.
  ///
  /// Physical-keyboard only (never pops the mobile soft keyboard); no-ops if
  /// we've already left [expectedStep] by the time the frame runs.
  void _focusPickerSearch(_ComposeStep expectedStep) {
    if (!hasPhysicalKeyboard()) return;
    _pickerSearchFocusNode.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _step == expectedStep) {
        _pickerSearchFocusNode.requestFocus();
      }
    });
  }

  /// Step 1 people pill -> step 2, or straight to compose when the user has
  /// messaged this **exact** roster before. In that skip case we default to the
  /// connection last used with these recipients ([ComposeTargetsBloc.
  /// lastUsedTargetForRoster]) and jump to compose, but still set
  /// [_selectedRecipient] so the compose connection field can navigate "back"
  /// to the connection step (see [_backFromCompose]). Otherwise we stash the
  /// step-1 query, clear the shared field for "Select a connection", and show
  /// step 2.
  Future<void> _pickRecipient(ComposePeopleEntry entry) async {
    final remembered = await context
        .read<ComposeTargetsBloc>()
        .lastUsedTargetForRoster(
          contacts: entry.contacts,
          groups: entry.groups,
          inviteEmails: entry.inviteEmails,
        );
    if (!mounted) return;
    _stashedSectionsQuery = _pickerSearchController.text;
    _pickerSearchController.clear();
    if (remembered != null) {
      setState(() => _selectedRecipient = entry);
      await _applyTarget(remembered);
      return;
    }
    setState(() {
      _selectedRecipient = entry;
      _step = _ComposeStep.connection;
    });
    _publishHeaderBack();
    _focusPickerSearch(_ComposeStep.connection);
  }

  /// Step 1 twist/channel/private-note pill -> compose (skip step 2). Clears the
  /// recipient so compose-step back-nav returns to step 1.
  Future<void> _applyDirectTarget(ComposeTarget target) async {
    setState(() => _selectedRecipient = null);
    await _applyTarget(target);
  }

  /// Opens the create-topic modal — team scope (when the user belongs to ≥1
  /// team), topic name, and a contact+group members picker — and creates the
  /// Plot topic. Returns true when a topic was created so the picker reloads its
  /// Channels list to surface it.
  Future<bool> _createTopic() async {
    final teams = await TeamUser.getActive();
    if (!mounted) return false;

    final items = <FormItem>[
      FormInfo(
        key: 'about',
        text:
            'Topics share Plot threads. When someone is added, they see all the '
            'threads and can choose a focus to put them in.',
        divider: true,
      ),
      FormTextInput(
        key: 'name',
        label: 'Name',
        required: true,
        placeholder: 'e.g. Marketing',
      ),
    ];

    // Team scope is offered only when the user belongs to ≥1 team; otherwise
    // every topic is Personal and the field would be a pointless single option.
    if (teams.isNotEmpty) {
      final scopes = <_TopicScope>[
        const _TopicScope(teamId: null, name: 'Personal'),
        for (final t in teams) _TopicScope(teamId: t.teamId, name: t.teamName),
      ];
      items.add(
        FormSelect<_TopicScope>(
          key: 'team',
          label: 'Team',
          items: (_) async => scopes,
          titleBuilder: (s) => s.name,
          initialValue: scopes.first,
        ),
      );
    }

    items.add(
      FormShareSelect(
        key: 'members',
        label: 'Members',
        placeholder: 'Add people and groups',
      ),
    );

    items.add(
      FormButton(
        key: 'create',
        isPrimary: true,
        buildCommand: (values) {
          final name = (values['name'] as String?)?.trim() ?? '';
          final scope = values['team'] as _TopicScope?;
          final members = values['members'] as SharedSelection?;
          return CreateTopic(
            name: name,
            teamId: scope?.teamId,
            contactIds:
                members?.contacts.map((u) => u.toString()).toList() ?? const [],
            groupIds:
                members?.groups.map((u) => u.toString()).toList() ?? const [],
          );
        },
      ),
    );

    final form = FormData(
      title: 'New topic',
      dismissable: true,
      groups: [StaticFormGroup(items: items)],
    );
    final groups = await form.list();
    if (!mounted) return false;
    final result = await FormModal(
      form,
      groups: groups,
      rootContext: context,
      constraints: const BoxConstraints(maxHeight: 520, maxWidth: 460),
    ).run(context);
    if (result is! CommandDone) return false;
    // The modal has closed. Surface the new topic in the local store before the
    // caller reloads the Channels list. Kept off CreateTopic's critical path so
    // a slow or failing sync can't block the modal close; a sync failure here is
    // non-fatal (the topic still arrives on the next regular sync).
    try {
      await Topic.pull();
    } catch (e, t) {
      log.warning('Topic.pull after create failed', e, t);
      Tracker.captureException(e, t);
    }
    return true;
  }

  /// Opens the "… More" (Edit) menu for an editable people row. Non-editable
  /// pill kinds (twists, channels, topics, focuses, connections) are ignored.
  Future<void> _rowMore(ComposePillData data) async {
    final Command command;
    switch (data) {
      case ContactPillData(:final actor):
        command = EditContact(
          contactId: actor.id,
          currentName: actor.name ?? '',
          email: actor.email,
        );
      case GroupPillData(:final group, :final members):
        command = EditGroup(
          groupId: group.id,
          initialName: group.name,
          initialMemberContactIds: members.map((a) => a.id.toUuid()).toList(),
        );
      case AdHocGroupPillData(:final actors):
        command = EditGroup(
          groupId: null,
          initialName: '',
          initialMemberContactIds: actors.map((a) => a.id.toUuid()).toList(),
        );
      default:
        return; // not editable
    }
    final commands = Commands(
      groups: [
        StaticCommandGroup(commands: [command]),
      ],
    );
    await CommandModal(commands, rootContext: context).run(context);
  }

  /// "+ Contact" header button → add a contact. Returns true if added, and
  /// bumps the new contact to the top of the People MRU.
  Future<bool> _addContact() async {
    final bloc = context.read<ComposeTargetsBloc>();
    final result = await NewContact().run(context);
    if (result is CommandDone && result.createdId != null) {
      await bloc.recordPersonUsage(
        contacts: [Uuid.fromString(result.createdId!)],
        groups: const [],
        inviteEmails: const [],
      );
    }
    return result is CommandDone;
  }

  /// "+ Group" header button → create a group. Returns true if created, and
  /// bumps the new group to the top of the People MRU.
  Future<bool> _addGroup() async {
    final bloc = context.read<ComposeTargetsBloc>();
    final result = await EditGroup().run(context);
    if (result is CommandDone && result.createdId != null) {
      await bloc.recordPersonUsage(
        contacts: const [],
        groups: [Uuid.fromString(result.createdId!)],
        inviteEmails: const [],
      );
    }
    return result is CommandDone;
  }

  /// Step 2 ✕/Esc -> step 1, restoring the stashed filter text.
  void _returnToSectionsStep() {
    _pickerSearchController.text = _stashedSectionsQuery;
    setState(() => _step = _ComposeStep.sections);
    _publishHeaderBack();
    // Claim focus (drops-then-requests so it engages even though the shared
    // node was just focused on step 2).
    _focusPickerSearch(_ComposeStep.sections);
    // Select-all the restored filter in a later frame — after focus engages —
    // so the user can immediately retype to replace it. Kept separate from the
    // focus claim so a selection edit can't pre-empt the focus request.
    if (hasPhysicalKeyboard() && _stashedSectionsQuery.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _step != _ComposeStep.sections) return;
        final text = _pickerSearchController.text;
        if (text.isNotEmpty) {
          _pickerSearchController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: text.length,
          );
        }
      });
    }
  }

  /// Runs the current compose step's "go back" action, mirroring the mapping
  /// in [_publishHeaderBack] so the system back gesture (PopScope) and the
  /// header back chevron behave identically:
  ///
  ///   * compose (step 3) → [_backFromCompose]
  ///   * connection (step 2) → [_returnToSectionsStep]
  ///   * sections (step 1) → no step to go back to
  ///
  /// Returns true when a step-back was performed; false on step 1 (the caller
  /// then leaves the compose page entirely).
  bool _composeStepBack() {
    switch (_step) {
      case _ComposeStep.sections:
        return false;
      case _ComposeStep.connection:
        _returnToSectionsStep();
        return true;
      case _ComposeStep.compose:
        _backFromCompose();
        return true;
    }
  }

  /// Compose-step "go back": to step 2 when a recipient is chosen, else step 1.
  void _backFromCompose() {
    if (_selectedRecipient != null) {
      setState(() => _step = _ComposeStep.connection);
      _publishHeaderBack();
      _focusPickerSearch(_ComposeStep.connection);
    } else {
      _returnToSectionsStep();
    }
  }

  /// Suggests a concrete focus for [target] and switches the draft to it.
  ///
  /// Ranks the user's focuses by recency of authored threads filed with the
  /// same roster (see [ComposeTargetsBloc.rankFocusesForRoster]); the MRU-top
  /// focus becomes the pre-selected focus and the rest seed the focus picker's
  /// order. For a no-roster target (a Note, or a no-contact connector target)
  /// the roster ranking is empty, so it falls back to the **global** focus MRU
  /// ([ComposeTargetsBloc.rankFocusesGlobal]) — the focuses the user most
  /// recently filed any thread into — so step 2 still pre-selects a concrete
  /// MRU focus. No-op only when the user has no filed history at all.
  Future<void> _suggestFocusForTarget(ComposeTarget target) async {
    final bloc = _priorityBloc;
    if (bloc == null) return;
    // Focus-note targets carry their focus explicitly — pre-select it directly
    // instead of running the roster/global MRU suggestion.
    if (target.priorityId != null) {
      final priorities = await Priority.get(order: PriorityOrder.nested);
      if (!mounted) return;
      final p = priorities.where((x) => x.id == target.priorityId).firstOrNull;
      if (p != null) {
        setState(() => _focusSuggestionOrder = [p]);
        await _switchToPriority(p);
        return;
      }
    }
    final targetsBloc = context.read<ComposeTargetsBloc>();
    final rosterRank = await targetsBloc.rankFocusesForRoster(
      contacts: target.contacts,
      groups: target.groups,
    );
    if (!mounted) return;
    // A target carries a roster when the user picked anyone — a known contact,
    // a group, or a freshly typed (still-unresolved) email invite.
    final hasRoster = target.contacts.isNotEmpty ||
        target.groups.isNotEmpty ||
        target.inviteEmails.isNotEmpty;
    // Only consult the global MRU for a no-roster target with no roster
    // ranking; a roster-bearing target with no history keeps the current focus
    // (see [suggestedFocusRanking]), so skip the extra scan entirely there.
    final globalRank = (rosterRank.isEmpty && !hasRoster)
        ? await targetsBloc.rankFocusesGlobal()
        : const <Uuid>[];
    if (!mounted) return;
    final rankedIds = suggestedFocusRanking(
      rosterRank: rosterRank,
      globalRank: globalRank,
      hasRoster: hasRoster,
    );
    if (rankedIds.isEmpty) return;

    // Resolve the ranked ids to Priority objects via the nested focus list.
    final priorities = await Priority.get(order: PriorityOrder.nested);
    if (!mounted) return;
    // PriorityId is a typedef for Uuid, so the thread's priorityId keys the
    // map directly.
    final byId = {for (final p in priorities) p.id: p};
    final ranked = <Priority>[];
    for (final id in rankedIds) {
      final p = byId[id];
      // Skip Inbox focuses: "auto-organize"-style filing is gone, but a
      // suggestion should still land in a real focus, not an Inbox.
      if (p != null && !p.isInbox) ranked.add(p);
    }
    if (ranked.isEmpty) return;

    setState(() => _focusSuggestionOrder = ranked);
    // Pre-select the MRU-top focus.
    await _switchToPriority(ranked.first);
  }

  ConnectionChoice _resolveActiveConnectionChoice(PriorityState state) {
    if (_selectedTwist != null) {
      return ConnectionChoice.twist(
        _selectedTwist!,
        allInstances: state.twists,
      );
    }
    final active = state.draftNote.actions
        ?.whereType<CreateLinkUserAction>()
        .firstOrNull;
    if (active == null) return _plotChoiceForDraft(state);
    for (final target in _allConnectionTargets) {
      // For DM/address-mode targets `target.channel` is null and the
      // active CreateLinkUserAction's channelId is also null — the null
      // == null comparison via `?.channelId` handles that case.
      if (active.twistInstanceId == target.twist.id.toString() &&
          active.channelId == target.channel?.channelId &&
          active.linkType == target.linkType.type) {
        return ConnectionChoice.target(target);
      }
    }
    // Target not yet loaded — fall back so the field always has a value.
    return _plotChoiceForDraft(state);
  }

  /// Builds the single Plot connection choice for the draft, carrying the
  /// draft's team scope so the connection field shows "Plot" with the team
  /// (only when the user belongs to ≥1 team — see [PlotThreadChoice.scopeLabel]).
  PlotThreadChoice _plotChoiceForDraft(PriorityState state) {
    final teamId = state.draft.teamId;
    return PlotThreadChoice(
      teamId: teamId,
      teamName: teamId == null ? null : _teamNames[teamId],
      hasTeams: _hasTeams,
    );
  }

  /// The active create-link action attached to the draft note (if any).
  /// Used by the contacts picker / submit validator to scope behavior by
  /// `compose.targets` mode (channels / contacts / addresses).
  CreateLinkUserAction? get _activeCreateAction {
    final note = _priorityBloc?.state.draftNote;
    return note?.actions?.whereType<CreateLinkUserAction>().firstOrNull;
  }

  List<ContactChipValue> _resolveContactChips(PriorityState state) {
    final selfUuids = Actor.getCurrentUserActorIds()
        .map((a) => a.toUuid())
        .toSet();
    final draft = state.draft;
    final chips = <ContactChipValue>[];
    for (final id in draft.groups) {
      final g = Group.fromCache(id);
      if (g != null) chips.add(ContactChipGroup(g));
    }
    for (final id in draft.contacts) {
      if (selfUuids.contains(id)) continue;
      final actor = Actor.fromCache(ActorId.fromUuid(id));
      if (actor != null) chips.add(ContactChipActor(actor));
    }
    for (final email in draft.inviteEmails) {
      chips.add(ContactChipEmail(email));
    }
    return chips;
  }

  Future<void> _updateTitle(String? next) async {
    final bloc = _priorityBloc;
    if (bloc == null) return;
    await bloc.updateDraft(bloc.state.draft.copyWith(title: Value(next)));
  }

  Future<void> _openSharedPicker(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc>();
    // Pass the active connection's twistInstanceId so the picker filters
    // contacts to those reachable through THIS connection. For
    // `targets: "addresses"` (Gmail), pass the address-mode flag instead
    // and skip the connection filter — any contact with an email is
    // valid, and free-form email invites are allowed.
    final activeAction = _activeCreateAction;
    final isDm = activeAction?.isDmType ?? false;
    final isAddress = activeAction?.isAddressesType ?? false;
    final dmTwistInstanceId = isDm && !isAddress
        ? Uuid.fromString(activeAction!.twistInstanceId)
        : null;
    // Roles are connector-defined (email → To/CC/BCC, calendar →
    // Required/Optional, Slack/Linear → none). Forwarded into the picker
    // so already-shared rows render a role badge when there are ≥2 roles.
    final linkTypeCfg = _activeLinkTypeConfig;
    final roleConfigs = linkTypeCfg?.contactRoles;
    final sharingModel = linkTypeCfg?.sharingModel ?? SharingModel.thread;
    // Historical notes are needed only for message-mode threads (Dropped
    // section). Fetch them here so the commandsBuilder closure is async-safe.
    final draft = priorityBloc.state.draft;
    final notes = sharingModel == SharingModel.message
        ? await Note.getForThread(draft.id)
        : null;
    if (!context.mounted) return;
    await context.run(
      PickDraftThreadShared(
        thread: draft,
        dmTwistInstanceId: dmTwistInstanceId,
        isAddressMode: isAddress,
        roleConfigs: roleConfigs,
        sharingModel: sharingModel,
        notes: notes,
        onUpdate: (thread) async {
          if (!context.mounted) return;
          await priorityBloc.updateDraft(thread);
          // Sticky Chat: mark contacts added if the updated thread has any
          // contacts, groups, or invite-email recipients.
          if (thread.contacts.isNotEmpty ||
              thread.groups.isNotEmpty ||
              thread.inviteEmails.isNotEmpty) {
            _markContactsAdded();
          }
        },
      ),
    );
  }

  /// Opens a picker listing the enabled channels for [active]'s connection and
  /// switches the draft to the chosen channel.
  ///
  /// The options are the already-loaded [_allConnectionTargets] for the same
  /// connection + link type — [loadCreateTargets] enumerates one target per
  /// enabled channel, so switching is just selecting a different one. Applying
  /// it swaps the draft's [CreateLinkUserAction] (via [_applyConnectionChoice])
  /// while leaving the focus, title, and body untouched.
  Future<void> _openChannelPicker(
    BuildContext context,
    CreateTarget active,
  ) async {
    final options =
        _allConnectionTargets
            .where(
              (t) =>
                  !t.isDmType &&
                  t.twist.id == active.twist.id &&
                  t.linkType.type == active.linkType.type,
            )
            .toList()
          ..sort(
            (a, b) => (a.channel?.title ?? '').toLowerCase().compareTo(
              (b.channel?.title ?? '').toLowerCase(),
            ),
          );
    final selected = options
        .where((t) => t.channel?.channelId == active.channel?.channelId)
        .firstOrNull;
    final result = await SelectModal.open<CreateTarget>(
      context,
      items: (search) async {
        final query = search?.trim().toLowerCase() ?? '';
        final filtered = query.isEmpty
            ? options
            : options
                  .where(
                    (t) =>
                        (t.channel?.title ?? '').toLowerCase().contains(query),
                  )
                  .toList();
        return [SelectGroup<CreateTarget>(title: null, items: filtered)];
      },
      itemBuilder: (t, _) => ListTile(body: Text(t.channel?.title ?? '')),
      selectedValue: selected,
      prompt: 'Select a channel',
    );
    if (!result.present) return;
    if (!mounted) return;
    await _applyConnectionChoice(ConnectionChoice.target(result.value));
  }

  /// Returns a validation error message when submit should be blocked,
  /// or null if submit is allowed.
  ///
  /// - `targets: "channels"`: no extra validation.
  /// - `targets: "contacts"`: at least one selected contact must have a
  ///   `contact_external_account` row for the active connection.
  /// - `targets: "addresses"`: at least one recipient (contact with an
  ///   email, or a free-form invite email) must be present.
  String? _validateDmSubmit() {
    final action = _activeCreateAction;
    if (action == null || !action.isDmType) return null;

    final bloc = _priorityBloc;
    if (bloc == null) return null;
    final draft = bloc.state.draft;

    // Collect contacts selected on the draft (excluding self).
    final selfUuids = Actor.getCurrentUserActorIds()
        .map((a) => a.toUuid())
        .toSet();
    final contactIds = draft.contacts
        .where((id) => !selfUuids.contains(id))
        .toList();

    if (action.isAddressesType) {
      final hasRecipient =
          contactIds.any((id) {
            final actor = Actor.fromCache(ActorId.fromUuid(id));
            return actor?.email != null && actor!.email!.isNotEmpty;
          }) ||
          draft.inviteEmails.isNotEmpty;
      if (!hasRecipient) {
        return 'Add at least one recipient before sending.';
      }
      return null;
    }

    // `targets: "contacts"` — require a recipient reachable through this
    // specific connection.
    if (contactIds.isEmpty) {
      return 'Add at least one recipient before sending.';
    }
    final twistInstanceId = Uuid.fromString(action.twistInstanceId);
    final hasReachable = contactIds.any((id) {
      final actor = Actor.fromCache(ActorId.fromUuid(id));
      return actor != null && actor.hasExternalAccount(twistInstanceId);
    });
    if (!hasReachable) {
      return 'None of the selected recipients are reachable via this connection. '
          'They appear here after the workspace member sync completes.';
    }
    return null;
  }

  void _onTwistMentioned(String twistId) {
    final id = TwistInstanceId.fromString(twistId);
    final twist = TwistInstance.fromCache(id);
    if (twist == null) return;
    // Use the same connection-application path the picker uses so the
    // CreateLinkUserAction (if any) is cleared.
    unawaited(
      _applyConnectionChoice(
        ConnectionChoice.twist(
          twist,
          allInstances: context.read<PriorityBloc>().state.twists,
        ),
      ),
    );
  }

  void _selectTwist(TwistInstance twist, {bool recordUsage = true}) {
    setState(() => _selectedTwist = twist);
    final bloc = context.read<PriorityBloc>();
    bloc.updateDraftLocal(
      bloc.state.draft.copyWith(icon: Value('twist:${twist.twistId}')),
    );
    // Skipped when selecting a remembered default — a default must not feed
    // back into the mention ranking.
    if (recordUsage) {
      context.read<LocalPreferencesBloc>().recordMentionUsage(
        twist.id.toString(),
      );
    }
  }

  /// Computes the body-editor placeholder for the current compose mode.
  ///
  /// Plot targets: "Start a chat" when shared, otherwise "Add a note".
  /// [shared] is true when the draft has contacts/groups/emails OR the sticky
  /// [_hadContactsThisSession] flag is set.
  ///
  /// Connector targets: uses [composerHintForNewThread] (SDK copy or fallback).
  String _computeEditorHint(PriorityState state) {
    if (_feedbackMode) return 'Share feedback or ask for help';
    if (_selectedTwist != null) return "Chat with ${_selectedTwist!.name}";
    final cfg = _activeLinkTypeConfig;
    if (cfg != null) return composerHintForNewThread(cfg);
    // Plot target: mode-aware placeholder. A topic thread is always shared
    // (its audience is the topic membership).
    final draft = state.draft;
    final hasContacts =
        draft.contacts.isNotEmpty ||
        draft.groups.isNotEmpty ||
        draft.inviteEmails.isNotEmpty;
    final shared =
        hasContacts || _hadContactsThisSession || draft.topicId != null;
    return composerHintForNewThreadPlot(shared: shared);
  }

  /// Computes the label for the primary Save/Send button in new-thread mode.
  ///
  /// Plot targets: "Send" (shared) / "Save" (private).
  /// Connector targets: connector's composeVerb or "Create".
  String _computeSendLabel(PriorityState state) {
    final cfg = _activeLinkTypeConfig;
    if (_selectedTwist != null || cfg != null) {
      return composerVerbForNewThread(cfg);
    }
    // Plot target. A topic thread is always shared (posts to the topic).
    final draft = state.draft;
    final hasContacts =
        draft.contacts.isNotEmpty ||
        draft.groups.isNotEmpty ||
        draft.inviteEmails.isNotEmpty;
    final shared =
        hasContacts || _hadContactsThisSession || draft.topicId != null;
    return shared ? 'Send' : 'Save';
  }

  /// LinkTypeConfig of the connection target the user has selected for this
  /// new thread (e.g. "Linear issue"). Null when no target is selected or
  /// the target's twist/linkType is not in cache.
  LinkTypeConfig? get _activeLinkTypeConfig =>
      linkTypeConfigForCreateAction(_activeCreateAction);

  List<ActorId>? get _twistMentions =>
      _selectedTwist != null ? [ActorId(_selectedTwist!.id)] : null;

  Future<void> _handleDraftChanged(Thread thread, {Note? note}) async {
    // Use the cached bloc: this callback can fire from NoteEditor.deactivate()
    // after ancestors are detached, so context.read would throw.
    final bloc = _priorityBloc;
    if (bloc == null) return;

    // Always use the latest state from the bloc as our base. This prevents
    // rapid typing in NoteEditor from regressing the contact list or twist icon
    // that might have been updated by other UI elements (like the share modal
    // or twist picker) while this callback was in flight.
    final currentThread = bloc.state.draft;
    final nextContacts = {...currentThread.contacts};
    bool contactsChanged = false;

    // 1. Extract and add non-twist mentions from the note content
    if (note?.mentions != null) {
      for (final mention in note!.mentions!) {
        if (mention.isTwist) continue;

        if (nextContacts.add(mention.toUuid())) {
          contactsChanged = true;
          // Pre-fetch missing actors so the contact chips can show them
          // immediately on the next build.
          if (Actor.fromCache(mention) == null) {
            try {
              await Actor.getOne(mention);
            } catch (_) {}
          }
        }
      }
    }

    // 2. Also incorporate contacts from the 'thread' argument to ensure we don't
    // miss any legitimate updates from the NoteEditor (though rare for contacts).
    for (final id in thread.contacts) {
      if (nextContacts.add(id)) {
        contactsChanged = true;
      }
    }

    final updatedThread = currentThread.copyWith(
      contacts: contactsChanged
          ? Value(nextContacts.toList())
          : const Value.absent(),
      // Preserve other thread-level changes (like title/preview) from NoteEditor
      title: thread.title == currentThread.title
          ? const Value.absent()
          : Value(thread.title),
      preview: thread.preview == currentThread.preview
          ? const Value.absent()
          : Value(thread.preview),
    );

    // Update the bloc and persist changes.
    await bloc.updateDraft(updatedThread, note: note);

    // Sticky Chat: mark that the user has added contacts this session so the
    // Chat placeholder persists even if they remove contacts later.
    if (nextContacts.isNotEmpty) {
      _markContactsAdded();
    }
  }

  void _onChatSubmitted() {
    final prefs = context.read<LocalPreferencesBloc>();
    if (_selectedTwist != null) {
      prefs.recordMentionUsage(_selectedTwist!.id.toString());
    }
    // Record the chosen target globally so it floats to the top of the step-1
    // picker next time (records its signature in the connection MRU and
    // prepends it to the cached list). The two-step picker ranks by the global
    // MRU — no priority bias — so priorityId is omitted. Fire-and-forget: the
    // route flip to ThreadRoute follows immediately.
    final target = _selectedTarget;
    if (target != null) {
      unawaited(
        context.read<ComposeTargetsBloc>().recordTarget(target).catchError((
          Object e,
          StackTrace s,
        ) {
          Tracker.captureException(e, s);
        }),
      );
    }
    // Link mode: remember this destination as a recent *link* destination so it
    // floats to the top of the next link-mode picker. Independent of the
    // connection MRU recorded above.
    if (target != null) {
      final note = _priorityBloc?.state.draftNote;
      final hasLink =
          note?.actions?.whereType<ExternalUserAction>().isNotEmpty ?? false;
      if (hasLink) {
        unawaited(
          prefs.recordLinkUsage(target.signature).catchError((
            Object e,
            StackTrace s,
          ) {
            Tracker.captureException(e, s);
          }),
        );
      }
    }
    // Clear global search so the new thread is visible in the list
    _provider?.tryCloseSearch();
  }

  /// Whether to show the contacts row for the current [activeChoice].
  ///
  /// - Plot threads: **always** shown (no note/chat distinction), so a thread
  ///   started from a focus without contacts can still add recipients.
  /// - Connector targets: hidden when the [SharingModel] has no per-thread
  ///   recipient roster — [SharingModel.none] (e.g. Google Tasks — no audience
  ///   concept) and [SharingModel.channel] (e.g. a Slack channel, where the
  ///   audience is the channel's membership, not a per-thread contact set).
  ///   Shown for [SharingModel.thread] / [SharingModel.message].
  /// - Twist targets: always shown (chat with a twist).
  bool _shouldShowContacts(ConnectionChoice activeChoice) {
    if (activeChoice is PlotThreadChoice) {
      return true;
    }
    if (activeChoice is TargetConnectionChoice) {
      final model = activeChoice.target.linkType.sharingModel;
      return model == SharingModel.thread || model == SharingModel.message;
    }
    // TwistConnectionChoice: always show contacts (chat with a twist)
    return true;
  }

  /// Whether [target] has no per-thread recipient roster — a Plot **Note**, or
  /// a connector target whose [SharingModel] is [SharingModel.none] (e.g.
  /// Google Tasks — no audience concept) or [SharingModel.channel] (e.g. a
  /// Slack channel, whose audience is the channel membership and which surfaces
  /// a channel field rather than a contacts field). The negation of the
  /// [_shouldShowContacts] rule, expressed directly over a [ComposeTarget] so
  /// [_applyTarget] can clear the draft's roster when one is picked. Chat and
  /// the thread / message connector sharing models support a roster, so they
  /// are not no-roster.
  bool _targetHasNoRoster(ComposeTarget target) {
    switch (target.kind) {
      case ComposeTargetKind.note:
      // A topic's membership/routing is the audience — no per-thread roster.
      case ComposeTargetKind.topic:
        return true;
      case ComposeTargetKind.chat:
      case ComposeTargetKind.twist:
        return false;
      case ComposeTargetKind.connector:
        final model = target.linkType?.sharingModel;
        return model == SharingModel.none || model == SharingModel.channel;
    }
  }

  /// Horizontal page inset for the single-panel pickers (steps 1 & 2).
  ///
  /// Every other single-panel tab (focus list, agenda, search) renders its list
  /// edge-to-edge with leading content sitting at `spacing.lg` from the screen
  /// edge. The picker's rows and section headers already carry a `spacing.sm`
  /// internal inset (PillGrid's row chrome + header indent), so we subtract that
  /// from `spacing.lg` here. That lands the picker's content at the same
  /// `spacing.lg` margin as the other tabs, rather than stacking a full
  /// `contentPaddingH` (`spacing.xl`) gutter on top of the internal inset —
  /// which read as noticeably more padded than every other page.
  double _singlePanelPickerInset(BuildContext context) {
    final spacing = context.theme.spacing;
    return spacing.lg - spacing.sm;
  }

  /// Step 1: the inline sections picker. Picking a people pill advances to the
  /// connection step (see [_pickRecipient]); picking a twist/channel/focus pill
  /// skips straight to compose (see [_applyDirectTarget]). Returning here from
  /// the connection step restores the stashed filter text
  /// (see [_returnToSectionsStep]).
  ///
  /// Multi-panel: a comfortable fixed inset above the prompt, then the list
  /// fills the remaining height down to the bottom edge (where the scroll fade
  /// lives). Single-panel: edge-to-edge with the standard page padding.
  Widget _buildTargetPickerStep(
    BuildContext context, {
    required bool multiPanel,
  }) {
    // The "Private notes" section leads with the focus the user is currently
    // viewing, so the most likely note destination is the first option. In the
    // Everything view there's no current focus, so nothing is pinned.
    final priorityState = context.read<PriorityBloc>().state;
    final pinnedFocusId =
        priorityState.everything ? null : priorityState.context?.id;

    final picker = ComposeSectionsView(
      key: const ValueKey('new-thread-sections'),
      scrollController: _pickerScrollController,
      searchController: _pickerSearchController,
      searchFocusNode: _pickerSearchFocusNode,
      // Only multi-panel fades the panel, so only there does the "Start a
      // thread" hint need the level-holding boost. Single-panel and touch
      // devices never dim, so pass null (no boost) — boosting an un-faded hint
      // would over-darken it. Touch has no pointer to drive [_active], so the
      // hover-based dimming would otherwise leave the panel stuck muted.
      activeListenable: (multiPanel && !isTouchPlatform()) ? _active : null,
      onPickRecipient: (e) => unawaited(_pickRecipient(e)),
      onPickTarget: (t) => unawaited(_applyDirectTarget(t)),
      onCreateTopic: _createTopic,
      onRowMore: _rowMore,
      onAddContact: _addContact,
      onAddGroup: _addGroup,
      // Step 1 has no back affordance: the bottom-nav tab is the exit now
      // (tapping another tab parks the draft), and in multi-panel the
      // new-thread flow is the default right-panel so there's nothing to exit.
      pendingLink: _pendingLink,
      onClearLink: _clearPendingLink,
      pinnedFocusId: pinnedFocusId,
    );

    if (!multiPanel) {
      // Reserve the overlaid bottom-nav height so the sections list clears the
      // bar (single-panel keeps the bar on /new). Returns 0 in multi-panel.
      return Padding(
        padding: EdgeInsets.only(
          left: _singlePanelPickerInset(context),
          right: _singlePanelPickerInset(context),
          bottom: BottomNavInset.of(context),
        ),
        child: picker,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Calm breathing room above the prompt; the picker then fills the
          // remaining height so the list runs to the bottom of the panel.
          SizedBox(height: context.theme.spacing.lg),
          Expanded(child: picker),
        ],
      ),
    );
  }

  /// Step 2: the connection picker. Reached from step 1 by picking a people
  /// pill (see [_pickRecipient]). Shows the chosen recipient as a chip and the
  /// connections available to reach them; picking one advances to compose (see
  /// [_applyTarget]). The chip's ✕ / Esc returns to step 1
  /// (see [_returnToSectionsStep]). Mirrors [_buildTargetPickerStep]'s padding.
  Widget _buildConnectionStep(
    BuildContext context, {
    required bool multiPanel,
  }) {
    final view = ConnectionPickerView(
      key: const ValueKey('new-thread-connection'),
      recipient: _selectedRecipient!,
      scrollController: _pickerScrollController,
      searchController: _pickerSearchController,
      searchFocusNode: _pickerSearchFocusNode,
      onPickConnection: (t) => unawaited(_applyTarget(t)),
      onBack: _returnToSectionsStep,
      // Single-panel: the back lives in the header strip (fed by
      // ThreadHeaderNotifier.newThreadBack), so drop the in-field chevron.
      // Multi-panel has no header back, so keep it.
      showBackButton: multiPanel,
    );

    if (!multiPanel) {
      // Reserve the overlaid bottom-nav height (single-panel keeps the bar on
      // /new). Mirrors [_buildTargetPickerStep].
      return Padding(
        padding: EdgeInsets.only(
          left: _singlePanelPickerInset(context),
          right: _singlePanelPickerInset(context),
          bottom: BottomNavInset.of(context),
        ),
        child: view,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Calm breathing room above the prompt; the picker then fills the
          // remaining height so the list runs to the bottom of the panel.
          SizedBox(height: context.theme.spacing.lg),
          Expanded(child: view),
        ],
      ),
    );
  }

  /// Step-2 compose surface. Field order is **Connection → Focus → Contacts →
  /// Title** (the two-step redesign): the chosen connection sits at the top
  /// (tapping it re-opens the target picker), then the auto-suggested focus,
  /// then the recipient roster (hidden for no-roster targets per
  /// [_shouldShowContacts]), then the title. The body editor follows below.
  Widget _buildComposeSurface(BuildContext context, PriorityState state) {
    final activeChoice = _resolveActiveConnectionChoice(state);
    final showContacts = _shouldShowContacts(activeChoice);
    // A channel-sharing connection (Slack, Linear) shows a channel field in
    // place of the contacts field: the audience is the channel's membership,
    // and tapping the field switches which channel the thread targets.
    final channelTarget =
        activeChoice is TargetConnectionChoice &&
            activeChoice.target.linkType.sharingModel == SharingModel.channel
        ? activeChoice.target
        : null;

    // A thread posted into a Plot topic shows a topic field in place of the
    // contacts field: the audience is the topic's membership, not a per-thread
    // roster. Tapping it steps back to the target picker.
    final topicId = state.draft.topicId;
    final topicName = topicId == null ? null : Topic.fromCache(topicId)?.name;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConnectionComposeField(
          activeChoice: activeChoice,
          // Tapping the connection field goes back a step (to the connection
          // picker when a recipient was chosen, else the sections picker).
          openModal: () async => _backFromCompose(),
        ),
        PriorityComposeField(
          currentPriority: state.draft.priority,
          isAuto: false,
          openModal: () => _selectPriority(context, state),
        ),
        if (topicId != null)
          TopicComposeField(
            topicName: topicName ?? '',
            openModal: () async => _backFromCompose(),
          )
        else if (channelTarget != null)
          ChannelComposeField(
            channelTitle: channelTarget.channel?.title ?? '',
            openModal: () => _openChannelPicker(context, channelTarget),
          )
        else if (showContacts)
          ContactsComposeField(
            chips: _resolveContactChips(state),
            openModal: () => _openSharedPicker(context),
          ),
        TitleComposeField(
          key: _titleFieldKey,
          title: state.draft.title,
          onChanged: _updateTitle,
          onTabForward: () => _threadEditorKey.currentState?.focus(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      // Only the multiPanel flag affects this page's layout. Skipping panel
      // visibility / width changes avoids redundant rebuilds of the editor
      // tree as the LayoutBloc emits during load.
      buildWhen: (prev, curr) => prev.multiPanel != curr.multiPanel,
      builder: (context, layoutState) {
        // Single-panel mode is always active (no eye-catch dimming on mobile /
        // narrow layouts). OR-ed into the body opacity at render time.
        _singlePanel = !layoutState.multiPanel;
        return BlocBuilder<PriorityBloc, PriorityState>(
          // During initial load PriorityBloc emits 6-10 times (agenda,
          // activity feed, tags, icon counts, twists, actors). Only the
          // fields below actually affect this page's chrome — rebuilding
          // for the rest forces a fresh NoteEditor widget each emit and
          // is the primary cause of the on-open editor flicker.
          //
          // `twists` and `actors` are deliberately excluded: in production
          // with many contacts the Drift `Actor.watch` stream emits many
          // times during initial sync, and rebuilding the chip row +
          // scaffold on each emit makes the page visibly flicker until
          // the stream settles. NoteEditor subscribes to those fields
          // internally via its own BlocBuilder so the inner Editor still
          // sees fresh @-mention candidates.
          buildWhen: (prev, curr) =>
              prev.draft != curr.draft ||
              prev.draftNote != curr.draftNote ||
              prev.context != curr.context,
          builder: (context, state) {
            return PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, result) {
                if (!didPop) {
                  if (ModalProvider.tryDismissTopModal(context)) return;
                  final provider = ActivityPanelControllerProvider.maybeOf(
                    context,
                  );
                  if (provider != null && provider.tryCloseSearch()) return;
                  // Step back through the compose flow before leaving it, so
                  // the back gesture returns to the previous compose step
                  // (compose → connection → sections) instead of jumping
                  // straight out to the thread list. Only a back from step 1
                  // (sections) falls through to exit the compose page.
                  if (_composeStepBack()) return;
                  if (!context.isMultiPanel) {
                    context.run(ChangeCurrentThread(null));
                  }
                }
              },
              child: CallbackShortcuts(
                bindings: _buildThreadShortcuts(context, state),
                child: Scaffold(
                  translucent: true,
                  scrollable: false,
                  childPad: false,
                  // Active/inactive styling: the body fades between full
                  // strength and a muted resting state so it doesn't catch
                  // the eye when idle. The MouseRegion/Focus drive [_active]
                  // (via the notifier only — never setState — so the editor
                  // subtree isn't rebuilt on hover/focus), and the
                  // ValueListenableBuilder animates just the opacity layer.
                  body: MouseRegion(
                    opaque: false,
                    onEnter: (_) {
                      _mouseInside = true;
                      _dismissed = false;
                      _recomputeActive();
                    },
                    onExit: (_) {
                      _mouseInside = false;
                      _engaged = false;
                      _dismissed = false;
                      _recomputeActive();
                    },
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      // Track focus only to gate the key handler. Do NOT
                      // deactivate on focus-loss: the app drops/re-grabs focus
                      // internally (e.g. on reset), which would wipe a
                      // just-applied engagement. Mouse-leave / Esc deactivate.
                      onFocusChange: (hasFocus) => _pageFocused = hasFocus,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _active,
                        builder: (context, active, child) => AnimatedOpacity(
                          // Only the sections picker (step 1) dims when idle.
                          // The connection and compose steps are always full
                          // strength — like [_singlePanel], the step is OR-ed
                          // in here at render time (never folded into [_active])
                          // so a step change can't strand a stale value. Touch
                          // devices never dim: the hover that drives [_active]
                          // doesn't exist there, so dimming would leave the
                          // panel permanently muted.
                          opacity:
                              (active ||
                                  _singlePanel ||
                                  isTouchPlatform() ||
                                  _step != _ComposeStep.sections)
                              ? 1.0
                              : kNewThreadInactiveOpacity,
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                          child: child,
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            // Step 1: the inline sections picker. Shown on a fresh
                            // mount (and after the New-thread command remounts) in
                            // place of the compose surface + editor.
                            if (_step == _ComposeStep.sections) {
                              return _buildTargetPickerStep(
                                context,
                                multiPanel: layoutState.multiPanel,
                              );
                            }

                            // Step 2: the connection picker, reached by choosing a
                            // recipient in step 1.
                            if (_step == _ComposeStep.connection) {
                              return _buildConnectionStep(
                                context,
                                multiPanel: layoutState.multiPanel,
                              );
                            }

                            // Single panel mode: editor at bottom, edge-to-edge.
                            // Both the compose fields and the editor run
                            // full-bleed (no outer horizontal padding) so they
                            // share the same origin: each ComposeFieldRow's
                            // `composeIconLeft` gutter then lands the field icons
                            // at the same x as the NoteEditor's toolbar icons
                            // below — the same relative geometry as multi-panel
                            // (where both sit inside one shared Padding). An
                            // extra `contentPaddingH` wrapper here would only
                            // indent the fields, breaking that alignment.
                            if (!layoutState.multiPanel) {
                              // Reserve the overlaid bottom-nav height so the
                              // editor / action row sits above the bar when the
                              // keyboard is down. When the keyboard is up,
                              // viewInsets.bottom already pushes content past the
                              // bar (which the keyboard covers), so subtract it to
                              // avoid stacking a second gap on top of the keyboard.
                              final keyboardInset = MediaQuery.of(
                                context,
                              ).viewInsets.bottom;
                              final barInset = BottomNavInset.of(context);
                              final reserve = (barInset - keyboardInset).clamp(
                                0.0,
                                barInset,
                              );
                              // Compose fields + editor, bottom-aligned with
                              // the keyboard-inset reserve. The back affordance
                              // for this step lives in the header strip now
                              // (UnifiedHeader's single-panel new-thread branch,
                              // fed by ThreadHeaderNotifier.newThreadBack), so
                              // the page body fills its whole area with no
                              // in-page header row.
                              return Padding(
                                padding: EdgeInsets.only(bottom: reserve),
                                child: FocusTraversalGroup(
                                  policy: WidgetOrderTraversalPolicy(),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildComposeSurface(context, state),
                                      SizedBox(
                                        height: context.theme.spacing.md,
                                      ),
                                      Flexible(
                                        child: EditableArea(
                                          padding: false,
                                          position: EditableAreaPosition.bottom,
                                          flushToBottom: true,
                                          builder: (context, _) => Focus(
                                            canRequestFocus: false,
                                            skipTraversal: true,
                                            onKeyEvent: _handleEditorKeys,
                                            child: NoteEditor(
                                              key: _threadEditorKey,
                                              bodyOnly: true,
                                              draft: state.draftNote,
                                              thread: state.draft,
                                              onDraftChanged:
                                                  _handleDraftChanged,
                                              flushToBottom: true,
                                              showScheduleActions: false,
                                              hint: _computeEditorHint(state),
                                              sendLabel: _computeSendLabel(
                                                state,
                                              ),
                                              additionalMentions:
                                                  _twistMentions,
                                              onSubmitted: _onChatSubmitted,
                                              submitValidator:
                                                  _validateDmSubmit,
                                              selectedTwist: _selectedTwist,
                                              onTwistSelected: _selectTwist,
                                              onTwistMentioned:
                                                  _onTwistMentioned,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }

                            // Multi-panel mode: centered layout
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.start,
                                children: [
                                  Flexible(
                                    child: SizedBox(
                                      height: constraints.maxHeight * 0.25,
                                    ),
                                  ),
                                  Flexible(
                                    flex: 2,
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxHeight: constraints.maxHeight * 0.6,
                                      ),
                                      child: FocusTraversalGroup(
                                        policy: WidgetOrderTraversalPolicy(),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            _buildComposeSurface(
                                              context,
                                              state,
                                            ),
                                            SizedBox(
                                              height: context.theme.spacing.md,
                                            ),
                                            Flexible(
                                              child: EditableArea(
                                                padding: false,
                                                position:
                                                    EditableAreaPosition.bottom,
                                                flushToBottom: false,
                                                builder: (context, _) => Focus(
                                                  canRequestFocus: false,
                                                  skipTraversal: true,
                                                  onKeyEvent: _handleEditorKeys,
                                                  child: NoteEditor(
                                                    key: _threadEditorKey,
                                                    bodyOnly: true,
                                                    draft: state.draftNote,
                                                    thread: state.draft,
                                                    onDraftChanged:
                                                        _handleDraftChanged,
                                                    flushToBottom: false,
                                                    showScheduleActions: false,
                                                    hint: _computeEditorHint(
                                                      state,
                                                    ),
                                                    sendLabel:
                                                        _computeSendLabel(
                                                          state,
                                                        ),
                                                    additionalMentions:
                                                        _twistMentions,
                                                    onSubmitted:
                                                        _onChatSubmitted,
                                                    submitValidator:
                                                        _validateDmSubmit,
                                                    selectedTwist:
                                                        _selectedTwist,
                                                    onTwistSelected:
                                                        _selectTwist,
                                                    onTwistMentioned:
                                                        _onTwistMentioned,
                                                    autofocus:
                                                        !isMobilePlatform(),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Intercepts keys bubbling up from the focused body editor.
  ///
  /// **Escape** goes back a step — to the connection picker when a recipient
  /// was chosen, else the sections picker — the same "go back" as tapping the
  /// Connection field (see [_backFromCompose]). When a mention popover is open
  /// SuperEditor consumes Escape to close it first (it's a descendant of this
  /// Focus), so this fires only on a subsequent Escape. Other compose-step
  /// fields (title, etc.) route Escape through the page-level
  /// [_buildThreadShortcuts] binding instead, which is only present on the
  /// compose step.
  ///
  /// **Shift+Tab** sends focus back to the title field. SuperEditor doesn't
  /// consume Tab outside its mention popover, so the unhandled key reaches this
  /// Focus ancestor; a bare Tab is left to the default focus traversal.
  KeyEventResult _handleEditorKeys(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _backFromCompose();
      return KeyEventResult.handled;
    }
    if (event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    if (!HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    _titleFieldKey.currentState?.focus();
    return KeyEventResult.handled;
  }

  /// Builds keyboard shortcut bindings for thread-level actions on the
  /// NewThreadPage: go-back (Escape, step 2 only), share (contacts), priority,
  /// title. Note-level shortcuts are handled inside NoteEditor.
  Map<ShortcutActivator, VoidCallback> _buildThreadShortcuts(
    BuildContext context,
    PriorityState state,
  ) {
    return {
      // Escape on step 2 goes back to step 1 (the target picker), matching the
      // Connection-field "go back". Scoped to step 2 so step 1's own Escape
      // (clear filter / close composer) is left untouched. The editor's own
      // key handler ([_handleEditorKeys]) covers Escape while the body editor
      // holds focus; this covers the other step-2 fields (title, etc.).
      if (_step == _ComposeStep.compose)
        const SingleActivator(LogicalKeyboardKey.escape): _backFromCompose,
      // ⌘⇧S — share (contacts)
      platformSingleActivator(LogicalKeyboardKey.keyS, shift: true): () {
        _openSharedPicker(context);
      },
      // ⌘⇧P (⌘⌃⇧P on web) — change priority
      platformSingleActivator(
        LogicalKeyboardKey.keyP,
        shift: true,
        alt: kIsWeb,
      ): () {
        _selectPriority(context, state);
      },
      // ⌘⇧H — focus title input
      platformSingleActivator(LogicalKeyboardKey.keyH, shift: true): () {
        _titleFieldKey.currentState?.focus();
      },
    };
  }
}

/// A team-scope option for the create-topic modal's team field: null [teamId]
/// is Personal, otherwise a team and its display [name].
class _TopicScope {
  const _TopicScope({required this.teamId, required this.name});
  final BigInt? teamId;
  final String name;
}

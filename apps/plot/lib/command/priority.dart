import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'command.dart';
import 'package:plot/command/focus_suggestions.dart';
import 'package:plot/util/priority_nav.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/priorities_shell.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/color_dot.dart';
import 'package:plot/widget/time_tracking_modal.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/router.dart';

abstract class PriorityCommand extends Command {
  PriorityCommand(
    this.priority, {
    required super.eventObject,
    required super.eventAction,
    bool ancestry = true,
    String? label,
    IconData? glyph,
  }) : _label = label,
       // Public names so subclasses forward via `super.label` / `super.glyph`;
       // that rules out an initializing formal (which needs a private name).
       // ignore: prefer_initializing_formals
       _glyph = glyph,
       super(
         title: label ?? priority?.title ?? 'None',
         subtitle: ancestry && label == null
             ? (priority?.root == true
                   ? null
                   : (priority?.ancestorsLabel() ?? priority?.title))
             : null,
       );

  final Priority? priority;

  /// When set, the row renders as a fixed semantic view (the Inbox /
  /// Everything feeds) with this wording and [_glyph] in the brand colour
  /// instead of the root focus's own title, icon, and colour. [label] also
  /// becomes the searchable [Command.title].
  final String? _label;
  final IconData? _glyph;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) => null;

  @override
  Widget? buildBody(BuildContext context) {
    if (priority == null) return null;
    if (_label != null) {
      return FocusLabel(
        priority: priority!,
        titleOverride: _label,
        iconOverride: _glyph,
        color: context.colour.colours.fromTheme(
          const ThemeColor.defaultColor(),
        ),
      );
    }
    return FocusLabel(priority: priority!);
  }
}

class ChangeCurrentPriority extends PriorityCommand {
  ChangeCurrentPriority(
    Priority super.priority, {
    super.ancestry = true,
    this.selectedBlockId,
    this.everything = false,
    super.label,
    super.glyph,
  }) : super(
         eventObject: EventObject.priority,
         eventAction: EventAction.viewed,
       );

  /// When true, switch to the synthetic "Everything" feed rooted on this
  /// priority (the root): every thread across the Inbox and all focuses,
  /// unscoped. Sets [NowBloc.everything], which the priority page mirrors
  /// into the feed scope. Any ordinary navigation passes false, so moving to
  /// a focus or the Inbox leaves Everything mode.
  final bool everything;

  /// When this change originates from tapping a block in the agenda,
  /// the tapped [AgendaBlock.id]. Passed through to
  /// [NowBloc.setContext] so the agenda highlights exactly that block
  /// instead of the current-time block. Null for every other entry
  /// point (priority tree, header, command palette), which clears any
  /// prior agenda selection.
  final String? selectedBlockId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Flip the priority highlight immediately instead of waiting for the
    // new PriorityBloc to finish loading drafts and emit its new context.
    final nowBloc = context.read<NowBloc>();
    if (nowBloc.state is NowLoaded) {
      // Selecting a priority is an explicit "show me this priority"
      // action, so clear any sticky event selection — even when the
      // chosen priority is the same as the event's priority (setContext
      // would otherwise preserve it).
      nowBloc.setCurrentEvent(null);
      nowBloc.setContext(
        priority,
        selectedBlockId: selectedBlockId,
        everything: everything,
      );
    }

    final tabsRouter = _tabsRouterOrNull(context);
    PrioritiesShell.sourceTab = computeSourceTabAfterPriorityTap(
      activeTabIndex: tabsRouter?.activeIndex,
      currentSourceTab: PrioritiesShell.sourceTab,
    );

    final targetPriorityIdString = priority!.id.toShortString();
    // `context` here is the CommandModal's rootContext, which can be the
    // global CommandScope from GlobalShortcuts — that scope sits above
    // LayoutStateProvider, so `read<LayoutBloc>()` throws. `isMultiPanel`
    // does a nullable read and falls back to MediaQuery.
    final multi = context.isMultiPanel;

    // Same-priority fast path: when the priority the user tapped is
    // already on the Activity tab's stack, `root.navigate(PriorityRoute(
    // X, children: null))` does something destructive to the inner
    // [PriorityOnlyRoute] (drops it without remounting) and produces
    // a forever-spinner. Skip the navigate, switch tabs explicitly,
    // and force-refresh the inner route so Android's predictive-back
    // dispatcher re-registers PopScope on the active page.
    if (isSamePriorityAtActivityTop(
      tabsRouter: tabsRouter,
      targetPriorityIdString: targetPriorityIdString,
      priorityRouteName: PriorityRoute.name,
    )) {
      if (tabsRouter!.activeIndex != PriorityTabs.activity) {
        tabsRouter.setActiveIndex(PriorityTabs.activity);
      }
      final innerRouter = findPriorityInnerRouter(
        context.router.root,
        PriorityRoute.name,
      );
      if (innerRouter != null) {
        innerRouter.replaceAll([
          multi ? NewThreadRoute() : PriorityOnlyRoute(),
        ]);
      }
      return const CommandDone();
    }

    // Mark for URL-history replace when this is an in-tab navigation
    // (priority-to-priority while already on the Activity tab) so the
    // browser/Cmd+[ history doesn't accumulate one entry per priority
    // the user paged through. Cross-tab arrivals (Priorities/Agenda →
    // Activity) push so back walks back to the originating tab.
    if (isOnActivityTab(tabsRouter)) {
      context.router.root.navigationHistory.markUrlStateForReplace();
    }

    // In multi-panel mode the right panel should land on NewThreadPage for
    // the new priority. Passing it as a child here drives AutoRoute to
    // reconcile the inner stack to [NewThreadRoute] without going through
    // the PriorityOnlyPage→LoadingPage redirect that used to flash.
    return CommandRoute(
      PriorityRoute(
        priorityIdString: targetPriorityIdString,
        children: multi ? [NewThreadRoute()] : null,
      ),
    );
  }
}

/// Returns the [AutoTabsRouter] for [PrioritiesShell] if visible from
/// [context]. Returns null when out of scope (e.g. command triggered
/// from a modal outside the shell tree) so callers can fall back
/// gracefully.
TabsRouter? _tabsRouterOrNull(BuildContext context) {
  try {
    return AutoTabsRouter.of(context);
  } catch (_) {
    return null;
  }
}

/// The focus switcher: every focus, then the two fixed semantic views — the
/// Inbox (root) and the synthetic Everything feed — pinned to the bottom. The
/// group is header-less; Inbox and Everything reuse [ChangeCurrentPriority]
/// (rooted on the root priority) with branded labels.
class _FocusSwitchGroup extends CommandGroup {
  _FocusSwitchGroup();

  @override
  Future<List<Command>> list({String? search}) async {
    final priorities = await Priority.get(order: PriorityOrder.recent);
    Priority? root;
    final focuses = <Priority>[];
    for (final priority in priorities) {
      if (priority.root) {
        root = priority;
      } else {
        focuses.add(priority);
      }
    }
    final commands = <Command>[
      ...focuses.map((priority) => ChangeCurrentPriority(priority)),
      if (root != null) ...[
        ChangeCurrentPriority(root, label: 'Inbox', glyph: PlotIcon.inbox),
        ChangeCurrentPriority(
          root,
          everything: true,
          label: 'Everything',
          glyph: PlotIcon.inboxes,
        ),
      ],
    ];
    return CommandGroup.filter(commands, search);
  }
}

class ChangeCurrentPriorityCommands extends Commands {
  ChangeCurrentPriorityCommands()
    : super(
        groups: [_FocusSwitchGroup()],
        secondaryCommand: (prompt) => AddFocus(),
      );
}

class OpenPriority extends Command {
  OpenPriority(Priority priority)
    : priorityId = priority.id,
      super(
        title: "Open",
        eventObject: EventObject.priority,
        eventAction: EventAction.opened,
        icon: PlotIcon.open,
      );

  OpenPriority.byId(this.priorityId)
    : super(
        title: "Open",
        eventObject: EventObject.priority,
        eventAction: EventAction.opened,
        icon: PlotIcon.open,
      );

  final PriorityId priorityId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final targetPriorityIdString = priorityId.toShortString();
    final multi = context.isMultiPanel;
    final tabsRouter = _tabsRouterOrNull(context);
    PrioritiesShell.sourceTab = computeSourceTabAfterPriorityTap(
      activeTabIndex: tabsRouter?.activeIndex,
      currentSourceTab: PrioritiesShell.sourceTab,
    );
    // Same-priority fast path — see [ChangeCurrentPriority.run].
    if (isSamePriorityAtActivityTop(
      tabsRouter: tabsRouter,
      targetPriorityIdString: targetPriorityIdString,
      priorityRouteName: PriorityRoute.name,
    )) {
      if (tabsRouter!.activeIndex != PriorityTabs.activity) {
        tabsRouter.setActiveIndex(PriorityTabs.activity);
      }
      final innerRouter = findPriorityInnerRouter(
        context.router.root,
        PriorityRoute.name,
      );
      if (innerRouter != null) {
        innerRouter.replaceAll([
          multi ? NewThreadRoute() : PriorityOnlyRoute(),
        ]);
      }
      return const CommandDone();
    }
    if (isOnActivityTab(tabsRouter)) {
      context.router.root.navigationHistory.markUrlStateForReplace();
    }
    return CommandRoute(
      PriorityRoute(
        priorityIdString: targetPriorityIdString,
        children: multi ? [NewThreadRoute()] : null,
      ),
    );
  }
}

class PickCurrentPriority extends ShowCommands {
  PickCurrentPriority()
    : super(
        title: 'Switch focuses',
        icon: PlotIcon.priority,
        shortcut: platformSingleActivator(LogicalKeyboardKey.keyJ, alt: kIsWeb),
        commands: ChangeCurrentPriorityCommands(),
      );
}

class AddPriority extends Command {
  AddPriority(this._priority, {this.suggestionKey})
    : super(
        title: 'Create focus',
        icon: PlotIcon.save,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final Future<Priority> _priority;

  /// When this focus was created from a curated suggestion, its key — recorded
  /// as dismissed once the save succeeds so the suggestion stops appearing.
  final String? suggestionKey;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priority = await _priority;
    final savedPriority = await priority.save();
    if (suggestionKey != null) {
      await DismissedFocusSuggestions.add(suggestionKey!);
    }
    final multi = context.mounted ? context.isMultiPanel : false;
    if (context.mounted) {
      final tabsRouter = _tabsRouterOrNull(context);
      PrioritiesShell.sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: tabsRouter?.activeIndex,
        currentSourceTab: PrioritiesShell.sourceTab,
      );
    }
    return CommandRoute(
      PriorityRoute(
        priorityIdString: savedPriority.id.toShortString(),
        children: multi ? [NewThreadRoute()] : null,
      ),
      replace: true,
    );
  }
}

class EditPriority extends Command {
  EditPriority(this._priority)
    : super(
        title: 'Save',
        icon: FontAwesomeIcons.check,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final Future<Priority> _priority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priority = await _priority;
    await priority.save();
    return const CommandDone();
  }
}

class TogglePriorityArchived extends Command {
  TogglePriorityArchived(Priority priority)
    : _priority = Future.value(priority),
      super(
        title: priority.archivedAt != null ? 'Un-archive' : 'Archive',
        eventObject: EventObject.priority,
        eventAction: priority.archivedAt != null
            ? EventAction.unarchived
            : EventAction.archived,
        icon: PlotIcon.archived,
      );

  final Future<Priority> _priority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priority = await _priority;
    if (priority.root) {
      return CommandMessage(
        "The default focus can't be archived",
        isError: true,
      );
    }
    final isArchived = priority.archivedAt != null;
    await priority
        .copyWith(archivedAt: Value(isArchived ? null : DateTime.now()))
        .save();
    return const CommandDone();
  }
}

/// Builds the FormData for creating a new priority.
/// [submitBuilder] controls what command the form button creates.
Future<FormData> _buildNewPriorityForm(
  BuildContext context, {
  Priority? parent,
  required Command Function(Future<Priority> priority) submitBuilder,
}) async {
  final prioritiesBloc = context.read<PrioritiesBloc>();
  final nowBloc = context.read<NowBloc>();
  final currentPriority = nowBloc.state is NowLoaded
      ? (nowBloc.state as NowLoaded).priority
      : null;
  final defaultParent =
      parent ??
      currentPriority ??
      prioritiesBloc.state.root ??
      await Priority.getDefault();

  // Focuses are flat — no parent selector. A focus is created under the root
  // (the Inbox); the server defaults the parent to root for flat clients.
  final iconSelect = _focusIconSelect();

  return FormData(
    title: 'Add a focus',
    groups: [
      StaticFormGroup(
        items: [
          FormTextInput(key: 'title', label: 'Focus name', required: true),
          iconSelect,
          FormSelect<ThemeColor>(
            key: 'color',
            label: 'Color',
            initialValue: const ThemeColor.defaultColor(),
            hasInitialValue: true,
            items: (search) async => ThemeColor.options
                .where(
                  (c) =>
                      search == null ||
                      c.label.toLowerCase().startsWith(search.toLowerCase()),
                )
                .toList(),
            titleBuilder: (c) => c.label,
            leadingBuilder: (c) => ColorDot(color: c),
          ),
          FormButton(
            key: 'create',
            isPrimary: true,
            buildCommand: (values) => submitBuilder(
              Future.value(_priorityFromValues(values, defaultParent)),
            ),
          ),
        ],
      ),
    ],
  );
}

class NewPriority extends ShowForm {
  NewPriority({Priority? parent})
    : super(
        title: 'Add a focus',
        icon: PlotIcon.add,
        form: (context) => _buildNewPriorityForm(
          context,
          parent: parent,
          submitBuilder: (priority) => AddPriority(priority),
        ),
      );
}

class _SaveAndReturnPriority extends Command {
  _SaveAndReturnPriority(this._priority, {required this.onSaved})
    : super(
        title: 'Create focus',
        icon: PlotIcon.save,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final Future<Priority> _priority;
  final void Function(Priority) onSaved;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priority = await _priority;
    final savedPriority = await priority.save();
    onSaved(savedPriority);
    return const CommandDone();
  }
}

/// Opens the new priority form and returns the created Priority, or null if cancelled.
/// Unlike NewPriority command, this doesn't navigate to the new priority.
Future<Priority?> createPriorityInline(
  BuildContext context, {
  Priority? parent,
}) async {
  Priority? result;

  final command = ShowForm(
    title: 'Add a focus',
    icon: PlotIcon.add,
    form: (context) => _buildNewPriorityForm(
      context,
      parent: parent,
      submitBuilder: (priorityFuture) =>
          _SaveAndReturnPriority(priorityFuture, onSaved: (p) => result = p),
    ),
  );

  await command.run(context);
  return result;
}

/// Builds an unsaved flat focus from the create-form [values], filed under
/// [root]. `icon` isn't a constructor field, so it's applied via copyWith.
///
/// Focuses are team-agnostic: the two-step target picker drives a new thread's
/// roster and team scope (via thread.team_id), so no team or per-focus default
/// sharing is collected here.
Priority _priorityFromValues(Map<String, dynamic> values, Priority root) {
  return Priority(
    title: values['title'] as String,
    parent: root,
    color: values['color'] as ThemeColor?,
    draft: true,
  ).copyWith(
    icon: Value(values['icon'] as String?),
    description: Value(values['description'] as String?),
  );
}

/// Icon picker over the curated focus icon set ([PlotIcon.focusIcons]).
/// Renders as a grid (like the emoji reaction picker) so icons are browsed
/// visually; labels are searchable and shown as tooltips. [initial] seeds the
/// selection — pass the focus's stored icon key when editing.
FormSelect<String> _focusIconSelect({String initial = 'bullseyePointer'}) {
  final keys = PlotIcon.focusIcons.keys.toList();
  return FormSelect<String>(
    key: 'icon',
    label: 'Icon',
    initialValue: keys.contains(initial) ? initial : keys.first,
    hasInitialValue: true,
    items: (search) async {
      if (search == null || search.isEmpty) return keys;
      final lower = search.toLowerCase();
      return keys
          .where(
            (k) => PlotIcon.focusIconLabel(k).toLowerCase().contains(lower),
          )
          .toList();
    },
    titleBuilder: PlotIcon.focusIconLabel,
    leadingBuilder: (k) => Icon(PlotIcon.focusIcon(k), size: 20),
    gridColumns: 6,
    gridCellSize: 48,
    gridCellSpacing: 8,
  );
}

/// Two-step focus creation. Step 1 collects the focus's name, description,
/// icon, colour and sharing. Step 2 surfaces the existing threads that match
/// the description so the user can review and deselect before the focus is
/// created with the kept ones filed in (and the deselected ones recorded as
/// negative examples). [skipMatching] creates the focus straight from step 1
/// (no thread-matching step). [prefill] opens step 1 with its fields populated;
/// the [AddFocus] picker uses this to seed the form from a curated suggestion.
class NewFocus extends Command {
  NewFocus({this.skipMatching = false, this.prefill})
    : super(
        title: 'Add a focus',
        icon: PlotIcon.add,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final bool skipMatching;
  final FocusPrefill? prefill;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final root =
        context.read<PrioritiesBloc>().state.root ??
        await Priority.getDefault();
    if (!context.mounted) return const CommandSkipped();

    // The step-1 form drives the rest of the flow from its own buttons:
    // "Find matching threads" fetches matches and pushes the review step as a
    // nested modal (so its Back button / Esc returns here with the description
    // intact), while "Create focus" skips matching and creates the focus
    // straight away.
    return ShowForm(
      title: 'Add a focus',
      icon: PlotIcon.add,
      form: (ctx) => _buildFocusDetailsForm(
        ctx,
        root: root,
        skipMatching: skipMatching,
        prefill: prefill,
      ),
    ).run(context);
  }
}

/// Entry point for "Add a focus". Loads the user's dismissed-suggestion set,
/// then either opens a picker (custom focus + remaining curated suggestions) or,
/// when no suggestions remain, opens the create form directly. Picking a
/// suggestion prefills the same two-step [NewFocus] form; creating from it
/// records the dismissal (see [DismissedFocusSuggestions]).
class AddFocus extends Command {
  AddFocus()
    : super(
        title: 'Add a focus',
        icon: PlotIcon.add,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final dismissed = await DismissedFocusSuggestions.get();
    final suggestions = visibleFocusSuggestions(dismissed);
    if (!context.mounted) return const CommandSkipped();

    // Nothing left to suggest — the picker would show only "Create a custom
    // focus", so skip straight to the create form.
    if (suggestions.isEmpty) {
      return NewFocus().run(context);
    }

    return ShowCommands(
      title: 'Add a focus',
      icon: PlotIcon.add,
      commands: Commands(
        groups: [
          StaticCommandGroup(commands: [_CreateCustomFocus()]),
          StaticCommandGroup(
            title: 'Suggestions',
            commands: [
              for (final s in suggestions) _CreateSuggestedFocus(s),
            ],
          ),
        ],
      ),
    ).run(context);
  }
}

/// "Create a custom focus" row — opens the empty two-step create form.
class _CreateCustomFocus extends Command {
  _CreateCustomFocus()
    : super(
        title: 'Create a custom focus',
        icon: PlotIcon.add,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  @override
  Future<CommandReturn> run(BuildContext context) => NewFocus().run(context);
}

/// A curated-suggestion row — opens the two-step create form prefilled.
class _CreateSuggestedFocus extends Command {
  _CreateSuggestedFocus(this.suggestion)
    : super(
        title: suggestion.title,
        subtitle: suggestion.description,
        icon: PlotIcon.focusIcon(suggestion.iconKey),
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final FocusPrefill suggestion;

  @override
  Future<CommandReturn> run(BuildContext context) =>
      NewFocus(prefill: suggestion).run(context);
}

/// Step 1 form for [NewFocus]. The description feeds the matching step; it is
/// not stored on the focus, and it sits just above the action buttons so the
/// matching-relevant text is the last thing the user fills in before searching.
///
/// When [skipMatching] is false the form offers two actions: a primary "Find
/// matching threads" (which fetches matches and opens the review step) and a
/// secondary "Create focus" (which skips matching entirely). Onboarding passes
/// [skipMatching] true — no threads are synced yet — so only "Create focus" is
/// shown.
Future<FormData> _buildFocusDetailsForm(
  BuildContext context, {
  required Priority root,
  required bool skipMatching,
  FocusPrefill? prefill,
}) async {
  final suggestionKey = prefill?.suggestionKey;
  return FormData(
    title: 'Add a focus',
    groups: [
      StaticFormGroup(
        items: [
          FormTextInput(
            key: 'title',
            label: 'Focus name',
            required: true,
            initialValue: prefill?.title,
          ),
          // Description last (just above the buttons): it feeds thread matching,
          // so it reads as the lead-in to "Find matching threads".
          FormTextInput(
            key: 'description',
            label: 'Description',
            required: true,
            maxLines: 3,
            placeholder: 'What belongs in this focus?',
            initialValue: prefill?.description,
          ),
          _focusIconSelect(initial: prefill?.iconKey ?? 'bullseyePointer'),
          FormSelect<ThemeColor>(
            key: 'color',
            label: 'Color',
            initialValue: prefill?.color ?? const ThemeColor.defaultColor(),
            hasInitialValue: true,
            items: (search) async => ThemeColor.options
                .where(
                  (c) =>
                      search == null ||
                      c.label.toLowerCase().startsWith(search.toLowerCase()),
                )
                .toList(),
            titleBuilder: (c) => c.label,
            leadingBuilder: (c) => ColorDot(color: c),
          ),
          if (skipMatching)
            FormButton(
              key: 'create',
              isPrimary: true,
              buildCommand: (values) => AddPriority(
                Future.value(_priorityFromValues(values, root)),
                suggestionKey: suggestionKey,
              ),
            )
          else ...[
            FormInfo(
              key: 'editThis',
              text:
                  "Writing a good description and selecting matching threads ensures the right threads end up in this focus.",
            ),
            FormButton(
              key: 'find',
              isPrimary: true,
              buildCommand: (values) => _FindMatchingThreads(
                values: values,
                root: root,
                suggestionKey: suggestionKey,
              ),
            ),
            FormButton(
              key: 'create',
              isPrimary: false,
              buildCommand: (values) => _CreateFocusWithThreads(
                values: values,
                root: root,
                matches: const [],
                selections: const {},
                suggestionKey: suggestionKey,
              ),
            ),
          ],
        ],
      ),
    ],
  );
}

/// Step-1 "Find matching threads" action: fetches the threads that match the
/// description, then opens the review step ([_ShowFocusMatches]) as a nested
/// modal. Running as a [FormButton] command, the form button shows its spinner
/// while the fetch is in flight, then transitions to the review modal. Because
/// the review step is nested, its Back button / Esc returns to this step-1 form
/// with the description intact so the user can edit and try again.
class _FindMatchingThreads extends Command {
  _FindMatchingThreads({
    required this.values,
    required this.root,
    this.suggestionKey,
  }) : super(
         title: 'Find matching threads',
         icon: PlotIcon.search,
         eventObject: EventObject.modal,
         eventAction: EventAction.opened,
       );

  final Map<String, dynamic> values;
  final Priority root;
  final String? suggestionKey;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final description = (values['description'] as String? ?? '').trim();
    final title = (values['title'] as String? ?? '').trim();

    var matches = <_FocusMatch>[];
    try {
      final resp = await api.post<Map<String, dynamic>>(
        '/sync/priorities/find-matching-threads',
        body: {'description': description, 'title': title},
      );
      final raw = (resp['matches'] as List?) ?? const [];
      matches = [
        for (final m in raw)
          if (m is Map && m['thread_id'] is String)
            _FocusMatch(
              threadId: m['thread_id'] as String,
              title: (m['title'] as String?)?.trim().isNotEmpty == true
                  ? m['title'] as String
                  : 'Untitled thread',
            ),
      ];
    } catch (e, stackTrace) {
      Tracker.captureException(e, stackTrace);
      // Fall through with no matches — the user can still create the focus.
    }

    if (!context.mounted) return const CommandSkipped();
    return _ShowFocusMatches(
      values: values,
      root: root,
      matches: matches,
      suggestionKey: suggestionKey,
    ).run(context);
  }
}

/// One matched thread surfaced in the focus-creation review step.
class _FocusMatch {
  const _FocusMatch({required this.threadId, required this.title});
  final String threadId;
  final String title;
}

/// Step 2 of [NewFocus]: review the threads that match the description. Pushed
/// as a nested modal by [_FindMatchingThreads], so the form header shows a Back
/// button and Esc returns to step 1 to edit the description and search again.
class _ShowFocusMatches extends ShowForm {
  _ShowFocusMatches({
    required Map<String, dynamic> values,
    required Priority root,
    required List<_FocusMatch> matches,
    String? suggestionKey,
  }) : super(
         title: 'Add a focus',
         icon: PlotIcon.add,
         form: (ctx) => _buildFocusMatchesForm(
           ctx,
           values: values,
           root: root,
           matches: matches,
           suggestionKey: suggestionKey,
         ),
       );
}

Future<FormData> _buildFocusMatchesForm(
  BuildContext context, {
  required Map<String, dynamic> values,
  required Priority root,
  required List<_FocusMatch> matches,
  String? suggestionKey,
}) async {
  return FormData(
    title: 'Add a focus',
    groups: [
      StaticFormGroup(
        items: [
          if (matches.isEmpty)
            FormInfo(
              key: 'no_matches',
              text:
                  'No matching threads found yet. Create the focus and file '
                  'threads into it as they come in.',
            )
          else ...[
            FormInfo(
              key: 'matches_hint',
              text:
                  'These threads look like they belong in this focus. Uncheck '
                  'any that don’t.',
            ),
            for (final m in matches)
              FormToggle(
                key: 'match_${m.threadId}',
                label: m.title,
                initialValue: true,
              ),
          ],
          FormButton(
            key: 'create',
            isPrimary: true,
            buildCommand: (selections) => _CreateFocusWithThreads(
              values: values,
              root: root,
              matches: matches,
              selections: selections,
              suggestionKey: suggestionKey,
            ),
          ),
        ],
      ),
    ],
  );
}

/// Creates the focus, files the kept matches into it (positive examples), and
/// records the deselected matches as negatives. Navigates to the new focus.
class _CreateFocusWithThreads extends Command {
  _CreateFocusWithThreads({
    required this.values,
    required this.root,
    required this.matches,
    required this.selections,
    this.suggestionKey,
  }) : super(
         title: 'Create focus',
         icon: PlotIcon.save,
         eventObject: EventObject.priority,
         eventAction: EventAction.added,
       );

  final Map<String, dynamic> values;
  final Priority root;
  final List<_FocusMatch> matches;
  final Map<String, dynamic> selections;
  final String? suggestionKey;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final focus = await _priorityFromValues(values, root).save();

    if (suggestionKey != null) {
      await DismissedFocusSuggestions.add(suggestionKey!);
    }

    final selected = <String>[];
    final deselected = <String>[];
    for (final m in matches) {
      (selections['match_${m.threadId}'] == true ? selected : deselected).add(
        m.threadId,
      );
    }

    // File the kept threads into the focus (mirrors a user move: a local
    // priority change plus the positive learning signal).
    for (final id in selected) {
      try {
        final thread = await Thread.getOne(Uuid.fromString(id));
        await thread.copyWith(priority: focus).save();
        await api.post<dynamic>(
          '/sync/priority-moves',
          body: {'thread_id': id, 'priority_id': focus.id.toString()},
        );
      } catch (e, stackTrace) {
        Tracker.captureException(e, stackTrace);
      }
    }

    // Record the deselected matches as negative examples for future matching.
    if (deselected.isNotEmpty) {
      try {
        await api.post<dynamic>(
          '/sync/priorities/negatives',
          body: {
            'negatives': [
              for (final id in deselected)
                {
                  'thread_id': id,
                  'priority_id': focus.id.toString(),
                  'source': 'deselected',
                },
            ],
          },
        );
      } catch (e, stackTrace) {
        Tracker.captureException(e, stackTrace);
      }
    }

    if (!context.mounted) return const CommandDone();
    return ChangeCurrentPriority(focus).run(context);
  }
}

class EditPriorityCommand extends ShowForm {
  EditPriorityCommand(Priority priority)
    : super(
        title: 'Edit focus',
        icon: PlotIcon.settings,
        form: (context) async {
          // Re-fetch priority to get latest data (e.g. after a previous save)
          final p = await Priority.getOne(priority.id);

          return FormData(
            title: 'Edit focus',
            groups: [
              StaticFormGroup(
                items: [
                  FormTextInput(
                    key: 'title',
                    label: 'Focus name',
                    initialValue: p.title,
                    required: true,
                  ),
                  _focusIconSelect(initial: p.icon ?? 'bullseyePointer'),
                  FormSelect<ThemeColor>(
                    key: 'color',
                    label: 'Color',
                    initialValue: p.color ?? const ThemeColor.defaultColor(),
                    hasInitialValue: true,
                    items: (search) async => ThemeColor.options
                        .where(
                          (c) =>
                              search == null ||
                              c.label.toLowerCase().startsWith(
                                search.toLowerCase(),
                              ),
                        )
                        .toList(),
                    titleBuilder: (c) => c.label,
                    leadingBuilder: (c) => ColorDot(color: c),
                  ),
                  FormButton(
                    key: 'save',
                    isPrimary: true,
                    buildCommand: (values) {
                      final title = values['title'] as String;
                      final color = values['color'] as ThemeColor?;
                      final icon = values['icon'] as String?;
                      // Focuses are team-agnostic: no team field. Per-focus
                      // default sharing is gone — the two-step target picker
                      // drives a thread's roster and team scope instead.
                      return EditPriority(
                        Future.value(
                          p.copyWith(
                            title: title,
                            color: Value(color),
                            icon: Value(icon),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          );
        },
      );
}

/// Opens a focus picker to merge [source]'s threads into another focus.
/// Selecting a target moves every thread filed under [source] into it and
/// then archives [source]. Shown on a focus only when it has threads (an
/// empty focus keeps the plain Archive command).
class MergeFocusInto extends ShowCommands {
  MergeFocusInto(this.source)
    : super(
        title: 'Merge into…',
        icon: PlotIcon.move,
        commandsBuilder: (context) => _buildTargets(source),
      );

  final Priority source;

  static Future<Commands> _buildTargets(Priority source) async {
    // `getRaw` skips the unread/active enrichment the picker doesn't display,
    // so the modal opens immediately (same reasoning as MoveThreadToPriority).
    final priorities = await Priority.getRaw(order: PriorityOrder.recent);
    Priority? root;
    final focuses = <Priority>[];
    for (final p in priorities) {
      if (p.root) {
        root = p;
      } else if (p.id != source.id) {
        focuses.add(p);
      }
    }
    final commands = <Command>[
      ...focuses.map((target) => MergeFocus(source, target)),
      if (root != null && source.id != root.id)
        MergeFocus(source, root, label: 'Inbox', glyph: PlotIcon.inbox),
    ];
    return Commands(
      prompt: 'Merge "${source.displayTitle}" into…',
      groups: [StaticCommandGroup(title: 'Focuses', commands: commands)],
    );
  }
}

/// Moves every thread filed under [_source] into the target focus, then
/// archives [_source]. Filing is per-user, so this only re-files the current
/// user's view and archives their copy of the source focus — teammates are
/// unaffected.
class MergeFocus extends PriorityCommand {
  MergeFocus(Priority source, super.target, {super.label, super.glyph})
    : _source = source,
      super(
        eventObject: EventObject.priority,
        eventAction: EventAction.archived,
      );

  final Priority _source;
  Priority get _target => priority!;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final source = _source;
    final target = _target;

    // Re-file the threads and archive the source in the background so the
    // modal closes and we navigate to the destination focus immediately —
    // rather than holding the modal open with no feedback while every thread
    // is re-filed (which can take seconds on a large focus). Re-filing is
    // reactive (Drift streams), so the destination feed fills in live as
    // saves land, and the source disappears once archived.
    unawaited(() async {
      try {
        // Re-file every thread filed under the source — including archived
        // threads and drafts — so nothing is stranded under the archived
        // source. The thread save() is what syncs the re-filing (the mechanism
        // MoveToPriority relies on). We intentionally skip the per-thread
        // /sync/priority-moves learning signal: a bulk merge is a deliberate
        // re-file, not N classifier-training events.
        //
        // Non-transactional by design for v1: a failure mid-loop leaves a
        // partial re-file (some threads moved) with the source NOT archived,
        // since archiving happens only after the loop completes. A future
        // improvement could batch the saves or use a server-side merge
        // endpoint.
        final threads = await Thread.get(
          priorityId: source.id,
          archived: null,
          draft: null,
        );
        for (final thread in threads) {
          await thread.copyWith(priority: target).save();
        }
        // Archive the source focus.
        await source.copyWith(archivedAt: Value(DateTime.now())).save();
      } catch (e, stackTrace) {
        Tracker.captureException(e, stackTrace);
      }
    }());

    // Always follow the threads to the destination focus. The source is being
    // archived, so there is nothing to stay on.
    return CommandRoute(
      PriorityRoute(priorityIdString: target.id.toShortString()),
    );
  }
}

class ShowPriorityCommands extends ShowCommands {
  ShowPriorityCommands(Priority priority, {bool current = false})
    : super(
        title: 'More',
        icon: PlotIcon.menu,
        commands: Commands(
          groups: current
              ? currentPriorityCommandGroups(priority)
              : priorityCommandGroups(priority),
        ),
      );
}

List<Command> prioritySecondaryCommands(Priority priority) => [
  // The Inbox (root) is a fixed tile — no name/icon/colour to edit.
  if (!priority.root) EditPriorityCommand(priority),
  ShowEarlyNotificationsSettings(priority),
  ShowTimeLog(priority),
  if (!priority.root) archiveOrMergeCommand(priority),
];

/// The destructive slot on a focus menu. An archived focus offers Un-archive;
/// an active focus with threads offers "Merge into…" (move its threads
/// elsewhere, then archive); an active empty focus offers a one-click Archive.
/// The Inbox (root) never reaches here (gated by the caller).
Command archiveOrMergeCommand(Priority priority) {
  if (priority.archivedAt != null) return TogglePriorityArchived(priority);
  if (priority.hasThreads) return MergeFocusInto(priority);
  return TogglePriorityArchived(priority);
}

List<Command> priorityCommands(Priority priority) => [
  ...prioritySecondaryCommands(priority),
];

/// Returns [focus] enriched with `hasThreads` taken from the sidebar's
/// already-computed [loaded] priority list, so current-focus menus show the
/// right Archive/"Merge into…" label without re-querying. Falls back to
/// [focus] unchanged (hasThreads = false) when it isn't in the list (e.g. the
/// sidebar is search-filtered).
Priority enrichFocusFromList(Priority focus, List<Priority> loaded) {
  for (final p in loaded) {
    if (p.id == focus.id) return focus.withHasThreads(p.hasThreads);
  }
  return focus;
}

List<Command> currentPriorityCommands(
  Priority priority, {
  BuildContext? context,
  NowState? nowState,
}) => [
  ...prioritySecondaryCommands(priority),
  if (context != null) ToggleArchivedVisibility(context: context),
  NewThread(),
  OpenNextThread(),
  OpenPreviousThread(),
  if (nowState != null) ...timerCommands(nowState),
];

List<StaticCommandGroup> priorityCommandGroups(Priority priority) => [
  StaticCommandGroup(
    title: priority.root ? 'Inbox' : 'Focus: ${priority.title}',
    commands: priorityCommands(priority),
  ),
];

List<StaticCommandGroup> currentPriorityCommandGroups(
  Priority priority, {
  BuildContext? context,
  NowState? nowState,
}) => [
  StaticCommandGroup(
    title: priority.root ? 'Inbox' : 'Focus: ${priority.title}',
    commands: currentPriorityCommands(
      priority,
      context: context,
      nowState: nowState,
    ),
  ),
];

class ToggleShowArchived extends Command {
  ToggleShowArchived({required this.showArchived})
    : super(
        title: showArchived ? 'Show active items' : 'Show archived items',
        subtitle: showArchived ? 'Hide archived items' : 'Show archived items',
        eventObject: EventObject.archived,
        eventAction: EventAction.viewed,
        icon: PlotIcon.archived,
      );

  final bool showArchived;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<PriorityBloc>().toggleShowArchived();
    return const CommandDone();
  }
}

/// Toggle archived visibility across the current priority's threads and
/// notes (and, via the priorities-list watcher, archived focuses too).
/// Backed by `showArchived` on `PriorityBloc` (and `ThreadBloc` when a thread
/// is open) so it stays independent of search and filter state.
class ToggleArchivedVisibility extends Command {
  ToggleArchivedVisibility._({required this.showingArchived})
    : super(
        title: showingArchived ? 'Hide archived' : 'Show archived',
        subtitle: showingArchived
            ? 'Hide archived threads, notes and focuses'
            : 'Show archived threads, notes and focuses',
        eventObject: EventObject.archived,
        eventAction: EventAction.viewed,
        icon: PlotIcon.archived,
      );

  factory ToggleArchivedVisibility({required BuildContext context}) {
    final showing = context.read<PriorityBloc>().state.showArchived;
    return ToggleArchivedVisibility._(showingArchived: showing);
  }

  final bool showingArchived;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<PriorityBloc>().toggleShowArchived();

    try {
      context.read<ThreadBloc>().toggleShowArchived();
    } on ProviderNotFoundException {
      // No thread open — nothing to toggle.
    }

    return const CommandDone();
  }
}

/// Toggle showing all priorities (active + archived) vs active only
class ToggleArchivedPrioritiesFilter extends Command {
  ToggleArchivedPrioritiesFilter({required this.showAllPriorities})
    : super(
        title: showAllPriorities
            ? 'Hide archived focuses'
            : 'Show archived focuses',
        subtitle: showAllPriorities
            ? 'Showing all focuses (active & archived)'
            : 'Showing active focuses only',
        eventObject: EventObject.filter,
        eventAction: EventAction.filtered,
        icon: PlotIcon.archived,
      );

  final bool showAllPriorities;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<LocalPreferencesBloc>().toggleShowAllPriorities();
    return const CommandDone();
  }
}

/// Open the [TimeTrackingModal] for a priority so users can review and
/// adjust recorded time. Surfaced from the priority's More modal.
class ShowTimeLog extends Command {
  ShowTimeLog(this.priority)
    : super(
        title: 'Time log',
        icon: PlotIcon.stopwatch,
        eventObject: EventObject.priority,
        eventAction: EventAction.viewed,
      );

  final Priority priority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await TimeTrackingModal(priority: priority).show<void>(context);
    return const CommandDone();
  }
}

/// Writes the global tracking-pause flag on user_settings. When paused,
/// the [NowBloc] driver does not extend [Session.resume] and the server's
/// event finalizer skips occurrences whose end falls inside the paused
/// window. [paused] = true pauses; false clears the timestamp.
Future<void> _setTrackingPaused({required bool paused}) async {
  final existing = await UserSettingsEntity.get();
  final companion = UserSettingsCompanion(
    // Sentinel epoch tells the server "explicit clear"; locally the
    // [LocalDateTimeConverter] just stores it. On the next push we
    // pass tracking_paused_at as is and the server's CASE handles it.
    trackingPausedAt: Value(
      paused
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    ),
    // Preserve other fields if a row already exists.
    enterBehavior: existing?.enterBehavior == null
        ? const Value.absent()
        : Value(existing!.enterBehavior),
    aiEnabled: existing?.aiEnabled == null
        ? const Value.absent()
        : Value(existing!.aiEnabled),
    onboardingCompleted: existing?.onboardingCompleted == null
        ? const Value.absent()
        : Value(existing!.onboardingCompleted),
  );
  await UserSettingsEntity.save(companion);
}

/// Pause time tracking globally. Surfaced from the priority header pill
/// when a session is active.
class PauseTracking extends Command {
  PauseTracking()
    : super(
        title: 'Pause',
        icon: FontAwesomeIcons.pause,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await _setTrackingPaused(paused: true);
    return const CommandDone();
  }
}

/// Resume time tracking globally. Surfaced from the priority header pill
/// when tracking is paused — phrased "Log time" to express the user-facing
/// effect of starting to accumulate time again.
class ResumeTracking extends Command {
  ResumeTracking()
    : super(
        title: 'Log time',
        icon: FontAwesomeIcons.play,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await _setTrackingPaused(paused: false);
    return const CommandDone();
  }
}

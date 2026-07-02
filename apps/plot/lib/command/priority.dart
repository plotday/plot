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
import 'package:plot/analytics/profile.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/priorities_shell.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/color_dot.dart';
import 'package:plot/widget/time_tracking_modal.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/state/last_open_focus.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/network_exception.dart';
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
         // Fall back to [Priority.displayTitle] (not the raw [title]) so the
         // Inbox is searchable/labelled as "Inbox" without a branded [label]
         // override — the raw root title is the stored "Everything".
         title: label ?? priority?.displayTitle ?? 'None',
         subtitle: ancestry && label == null
             ? (priority?.isInbox == true
                   ? null
                   : (priority?.ancestorsLabel() ?? priority?.title))
             : null,
         searchTerms: _roleSearchTerms(priority, label),
       );

  final Priority? priority;

  /// The owning role's name, exposed as hidden [Command.searchTerms] so a focus
  /// is findable by its role in command modals (the focus switcher) — but only
  /// when the user has more than one role, mirroring [FocusLabel]'s role-prefix
  /// display. Null for branded rows (Inbox/Everything use [label]) and
  /// role-less focuses (e.g. FYI). Combines with the role search baked into
  /// [Priority.matchesSearch], which backs the SelectModal-based focus pickers.
  static String? _roleSearchTerms(Priority? priority, String? label) {
    if (label != null) return null;
    final roleId = priority?.roleId;
    if (roleId == null || Role.cachedCount < 2) return null;
    return Role.fromCache(roleId)?.name;
  }

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

  /// Named constructor for opening the synthetic "Everything" feed.
  /// Unlike the default constructor this takes no [Priority] — the feed is
  /// unanchored to any specific focus. The route still navigates to the
  /// default-Inbox priority URL (so the URL is valid and back-navigation
  /// works), but [NowBloc] receives `setContext(null, everything: true)` so
  /// [PriorityBloc] enters the null-context Everything mode.
  ChangeCurrentPriority.everything()
      : selectedBlockId = null,
        everything = true,
        super(
          null,
          ancestry: false,
          label: 'Everything',
          glyph: PlotIcon.inboxes,
          eventObject: EventObject.priority,
          eventAction: EventAction.viewed,
        );

  /// When true, switch to the synthetic "Everything" feed: every thread
  /// across the Inbox and all focuses, unscoped. Sets [NowBloc.everything],
  /// which the priority page mirrors into the feed scope. Any ordinary
  /// navigation passes false, so moving to a focus or the Inbox leaves
  /// Everything mode.
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

    // Remember this deliberate pick as the device-local "last open focus" so
    // the next cold start reopens here instead of the Inbox. Null for the
    // synthetic "Everything" feed (the helper no-ops). Fire-and-forget — a
    // missed pref write is harmless and must not delay navigation.
    unawaited(recordLastOpenFocus(priority));
    // Also remember it as this role's most-recent focus, so opening the role on
    // desktop reopens here. No-op for the "Everything" feed and role-less
    // focuses (the helper guards both).
    unawaited(recordLastOpenFocusForRole(priority));

    final tabsRouter = _tabsRouterOrNull(context);
    PrioritiesShell.sourceTab = computeSourceTabAfterPriorityTap(
      activeTabIndex: tabsRouter?.activeIndex,
      currentSourceTab: PrioritiesShell.sourceTab,
    );

    // For the Everything entry the route target is the default-Inbox priority
    // (the URL must resolve to a real priority page). For ordinary focus
    // navigation it is the tapped focus itself.
    final String? targetPriorityIdString;
    if (everything && priority == null) {
      // Resolve the default Inbox from PrioritiesBloc (already loaded in the
      // widget tree) so we don't need a DB round-trip inside a command.
      final root = context.read<PrioritiesBloc>().state.root;
      targetPriorityIdString = root?.id.toShortString();
    } else {
      targetPriorityIdString = priority!.id.toShortString();
    }

    if (targetPriorityIdString == null) {
      // No inbox priority loaded yet — nothing to navigate to.
      return const CommandDone();
    }

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
    final inboxId = Priority.defaultInbox(priorities)?.id;
    Priority? root;
    final focuses = <Priority>[];
    for (final priority in priorities) {
      if (priority.id == inboxId) {
        root = priority;
      } else {
        focuses.add(priority);
      }
    }
    final commands = <Command>[
      ...focuses.map((priority) => ChangeCurrentPriority(priority)),
      if (root != null) ...[
        // The Inbox renders as the ordinary role focus it is (FocusLabel
        // brands it via `isInbox`: inbox glyph, role prefix, role colour).
        // Only "Everything" — the synthetic cross-focus aggregate — keeps a
        // branded label/glyph.
        ChangeCurrentPriority(root),
        ChangeCurrentPriority.everything(),
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
    // Refresh the user's focus count on the next sync.
    markUserAnalyticsProfileStale();
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
    final inboxId = Priority.defaultInbox(
      await Priority.getRaw(order: PriorityOrder.recent),
    )?.id;
    if (priority.id == inboxId) {
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
  final role = values['role'] as Role?;
  return Priority(
    title: values['title'] as String,
    parent: root,
    color: values['color'] as ThemeColor?,
    draft: true,
  ).copyWith(
    icon: Value(values['icon'] as String?),
    description: Value(values['description'] as String?),
    // Set the focus's role so the push sends `role_id`; the server's
    // `apply_role_change_to_focus` trigger applies follow-if-matching. Falls
    // back to the parent's role (set by the constructor) when no role field
    // was present (e.g. forms that predate the role picker).
    roleId: role != null ? Value(role.id) : const Value.absent(),
  );
}

/// Resolves the role to pre-select in a focus form. Uses [defaultRoleId] when
/// given (e.g. the sidebar's expanded role), otherwise the user's first role.
/// Returns null when the user has no roles yet (the field is then optional).
Future<Role?> _resolveInitialRole(RoleId? defaultRoleId) async {
  if (defaultRoleId != null) {
    final role = await Role.getOne(defaultRoleId);
    if (role != null) return role;
  }
  final roles = await Role.all();
  return roles.firstOrNull;
}

/// Builds the focus form's "Role" [FormSelect]. Selecting a role previews the
/// server's follow-if-matching behaviour: if the [colorField] still shows the
/// previously selected role's colour (i.e. the focus was following its role),
/// the colour updates to the newly selected role's colour. If the user picked a
/// custom colour (an override), it's left untouched. The server's
/// `apply_role_change_to_focus` trigger is the source of truth on save; this is
/// just a live preview. [onAdd] opens the inline Add role modal.
FormSelect<Role> _roleSelect({
  required Role? initialRole,
  required FormSelect<ThemeColor> colorField,
}) {
  // The role the colour is currently following, tracked across changes so we
  // only auto-update the colour when it hasn't been manually overridden.
  Role? followedRole = initialRole;
  late final FormSelect<Role> field;
  field = FormSelect<Role>(
    key: 'role',
    label: 'Role',
    required: true,
    initialValue: initialRole,
    hasInitialValue: initialRole != null,
    addLabel: 'Add role',
    items: (search) async => (await Role.all())
        .where(
          (r) =>
              search == null ||
              r.name.toLowerCase().contains(search.toLowerCase()),
        )
        .toList(),
    titleBuilder: (r) => r.name,
    // A role carries its colour as identity, so the name is rendered in the
    // role's colour rather than tagged with a leading ColorDot (which is for
    // colour selection only). [labelBuilder] colours both the modal list rows
    // and the selected-value chip.
    labelBuilder: (r) => RoleLabel(role: r),
    onAdd: (ctx) => createRoleInline(ctx),
    onChanged: () {
      final role = field.getValue();
      if (role == null) return;
      // Only follow the role's colour if the focus was still following the
      // previous role (its colour matches). A manual override is preserved.
      final followingColor =
          followedRole != null &&
          colorField.getValue() == followedRole!.displayColor;
      if (followingColor || followedRole == null) {
        colorField.setValue(role.displayColor);
      }
      followedRole = role;
    },
  );
  return field;
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
  NewFocus({this.skipMatching = false, this.prefill, this.defaultRoleId})
    : super(
        title: 'Add a focus',
        icon: PlotIcon.add,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final bool skipMatching;
  final FocusPrefill? prefill;

  /// The role to pre-select in the new focus's Role field (e.g. the sidebar's
  /// expanded role). Defaults to the user's first role when null.
  final RoleId? defaultRoleId;

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
        defaultRoleId: defaultRoleId,
      ),
    ).run(context);
  }
}

/// Entry point for "Add a focus". Opens the role chooser first ("Choose a role
/// to add a focus") — the user picks an existing role or adds a new one — then
/// shows the focus templates for that role. Picking a template (or "Other")
/// opens the prefilled two-step [NewFocus] form with the role pre-selected.
class AddFocus extends Command {
  AddFocus({this.defaultRoleId})
    : super(
        title: 'Add a focus',
        icon: PlotIcon.add,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  /// Pre-highlighted in the role chooser (e.g. the sidebar's currently-selected
  /// focus's role); the user can still pick another. Null highlights the user's
  /// first role.
  final RoleId? defaultRoleId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final initialRole = await _resolveInitialRole(defaultRoleId);
    if (!context.mounted) return const CommandSkipped();

    // Step 1 — choose (or add) a role. Selecting an existing role pops with it;
    // the "Add role" row creates one (name + colour) and pops with the new role.
    final chosen = await SelectModal.open<Role>(
      context,
      title: 'Choose a role to add a focus',
      selectedValue: initialRole,
      items: (search) async {
        final roles = await Role.all();
        final filtered = search == null
            ? roles
            : roles
                  .where(
                    (r) =>
                        r.name.toLowerCase().contains(search.toLowerCase()),
                  )
                  .toList();
        return [
          SelectGroup<Role>(items: filtered),
          SelectGroup<Role>(
            items: <Role>[],
            infoBuilder: (ctx) => addItemRow(ctx, label: 'Add role'),
            onActivate: (ctx) async {
              final role = await createRoleInline(ctx);
              if (role != null && ctx.mounted) {
                Modal.pop<Role>(ctx, Value(role));
              }
            },
          ),
        ];
      },
      itemBuilder: (role, _) => Builder(
        builder: (ctx) => Padding(
          padding: EdgeInsets.symmetric(
            horizontal: ctx.theme.spacing.lg,
            vertical: ctx.theme.spacing.md,
          ),
          // The role's colour is its identity, so the name is rendered in it
          // (not paired with a ColorDot, which is for colour selection only).
          child: RoleLabel(role: role),
        ),
      ),
    );
    if (!chosen.present || !context.mounted) return const CommandSkipped();

    // Step 2 — choose a focus template (or "Other") for the chosen role.
    return _showFocusTemplates(chosen.value).run(context);
  }
}

/// Step-2 picker: the curated focus templates for [role], with "Other" last and
/// no group heading. If every suggestion has been dismissed, only "Other" shows.
Command _showFocusTemplates(Role role) {
  return ShowCommands(
    title: 'Add a focus',
    icon: PlotIcon.add,
    commandsBuilder: (context) async {
      final dismissed = await DismissedFocusSuggestions.get();
      final suggestions = visibleFocusSuggestions(dismissed);
      return Commands(
        groups: [
          StaticCommandGroup(
            commands: [
              for (final s in suggestions)
                _CreateSuggestedFocus(s, defaultRoleId: role.id),
              _CreateOtherFocus(defaultRoleId: role.id),
            ],
          ),
        ],
      );
    },
  );
}

/// "Other" row — opens the empty two-step create form. Sits last in the
/// templates list as the catch-all.
class _CreateOtherFocus extends Command {
  _CreateOtherFocus({this.defaultRoleId})
    : super(
        title: 'Other',
        subtitle: "Describe anything you'd like to focus on",
        icon: PlotIcon.add,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final RoleId? defaultRoleId;

  @override
  Future<CommandReturn> run(BuildContext context) =>
      NewFocus(defaultRoleId: defaultRoleId).run(context);
}

/// A curated-suggestion row — opens the two-step create form prefilled.
class _CreateSuggestedFocus extends Command {
  _CreateSuggestedFocus(this.suggestion, {this.defaultRoleId})
    : super(
        title: suggestion.title,
        subtitle: suggestion.description,
        icon: PlotIcon.focusIcon(suggestion.iconKey),
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final FocusPrefill suggestion;
  final RoleId? defaultRoleId;

  @override
  Future<CommandReturn> run(BuildContext context) =>
      NewFocus(prefill: suggestion, defaultRoleId: defaultRoleId).run(context);
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
  RoleId? defaultRoleId,
}) async {
  final suggestionKey = prefill?.suggestionKey;
  final initialRole = await _resolveInitialRole(defaultRoleId);
  final colorField = FormSelect<ThemeColor>(
    key: 'color',
    label: 'Color',
    initialValue:
        prefill?.color ?? initialRole?.displayColor ?? const ThemeColor(0),
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
  );
  final roleField = _roleSelect(initialRole: initialRole, colorField: colorField);
  return FormData(
    title: 'Add a focus',
    groups: [
      StaticFormGroup(
        items: [
          // Role first: a focus is created within a role, so it's the lead-in.
          roleField,
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
          colorField,
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

/// Outcome of the background match fetch, surfaced to the review step.
class _MatchResult {
  const _MatchResult({required this.matches, required this.failed});

  /// The fetch (or local-store hydration) threw — distinct from "no matches".
  const _MatchResult.failure() : matches = const [], failed = true;

  final List<_FocusMatch> matches;
  final bool failed;
}

/// Fetches the threads that match [description]/[title] and hydrates each from
/// the local store. Never throws: failures are captured and returned as
/// [_MatchResult.failure] so the review step can still offer "Create focus".
Future<_MatchResult> _fetchMatches({
  required String description,
  required String title,
}) async {
  try {
    final resp = await api.post<Map<String, dynamic>>(
      '/sync/priorities/find-matching-threads',
      body: {'description': description, 'title': title},
    );
    final raw = (resp['matches'] as List?) ?? const [];
    final parsed = [
      for (final m in raw)
        if (m is Map && m['thread_id'] is String)
          (
            threadId: m['thread_id'] as String,
            title: (m['title'] as String?)?.trim().isNotEmpty == true
                ? m['title'] as String
                : 'Untitled thread',
            // Default to a strong score when absent so older responses keep
            // their pre-checked behaviour.
            score: (m['score'] as num?)?.toDouble() ?? 1.0,
          ),
    ];
    // Hydrate each match from the local store so the review rows render the
    // full thread (logo, header, title, preview). Best-effort: a thread that
    // can't be loaded falls back to its title in the row.
    final threads = await Future.wait([
      for (final p in parsed)
        Thread.getOne(Uuid.fromString(p.threadId)).then<Thread?>(
          (t) => t,
          onError: (_) => null,
        ),
    ]);
    return _MatchResult(
      matches: [
        for (var i = 0; i < parsed.length; i++)
          _FocusMatch(
            threadId: parsed[i].threadId,
            title: parsed[i].title,
            score: parsed[i].score,
            thread: threads[i],
          ),
      ],
      failed: false,
    );
  } catch (e, stackTrace) {
    Tracker.captureException(e, stackTrace);
    // Fall through with no matches — the user can still create the focus.
    return const _MatchResult.failure();
  }
}

/// Shared, mutable holder bridging the step-2 form builder and the in-modal
/// progress widget. The progress widget writes [result] when the fetch lands,
/// then triggers a form refresh so the builder rebuilds into the review UI.
class _MatchLoadState {
  _MatchLoadState(this.future);

  final Future<_MatchResult> future;

  /// Null while the fetch is in flight; set once it completes.
  _MatchResult? result;
}

/// Friendly, no-jargon status messages cycled while matching runs. Timer-driven
/// reassurance (not tied to real backend stages), looped if the fetch outlasts
/// the list.
const List<String> _matchingStatusMessages = [
  'Looking through your threads…',
  'Finding what fits…',
  'Gathering the best matches…',
  'Almost ready…',
];

/// Minimum time the progress UI stays up so a fast response doesn't flash.
const Duration _matchingMinDisplay = Duration(milliseconds: 600);

/// How long each status message shows before advancing.
const Duration _matchingMessageInterval = Duration(milliseconds: 1800);

/// In-modal progress shown while [load.future] is in flight. Cycles a spinner +
/// friendly status line, and on completion writes [load.result] and refreshes
/// the surrounding form into the review UI.
class _MatchingProgress extends StatefulWidget {
  const _MatchingProgress({required this.load});

  final _MatchLoadState load;

  @override
  State<_MatchingProgress> createState() => _MatchingProgressState();
}

class _MatchingProgressState extends State<_MatchingProgress> {
  int _messageIndex = 0;
  Timer? _cycleTimer;

  @override
  void initState() {
    super.initState();
    _cycleTimer = Timer.periodic(_matchingMessageInterval, (_) {
      if (!mounted) return;
      setState(() {
        _messageIndex = (_messageIndex + 1) % _matchingStatusMessages.length;
      });
    });
    _awaitResult();
  }

  Future<void> _awaitResult() async {
    final start = DateTime.now();
    final result = await widget.load.future;
    widget.load.result = result;

    // Hold the progress UI for at least the minimum window.
    final elapsed = DateTime.now().difference(start);
    final remaining = _matchingMinDisplay - elapsed;
    if (remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }

    if (!mounted) return;
    // Rebuild the surrounding form into the review UI.
    await FormScope.of(context)?.refresh?.call();
  }

  @override
  void dispose() {
    _cycleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.theme.spacing.xl,
        vertical: context.theme.spacing.lg,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          const Spinner(),
          Flexible(
            child: Text(
              _matchingStatusMessages[_messageIndex],
              style: context.theme.typography.md.copyWith(
                color: context.theme.colors.mutedForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Step-1 "Find matching threads" action: starts the background fetch, then
/// immediately opens the review step ([_ShowFocusMatches]) as a nested modal in
/// a loading state. The modal's [_MatchingProgress] widget populates the review
/// UI when the fetch lands, so the user sees progress rather than a button
/// spinner. Because the review step is nested, its Back button / Esc returns to
/// this step-1 form with the description intact so the user can edit and try
/// again.
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

    // Start the fetch but DON'T await it — navigate to the review modal right
    // away so the user sees progress instead of a button spinner. The modal's
    // progress widget observes this future and populates the form when it lands.
    final load = _MatchLoadState(
      _fetchMatches(description: description, title: title),
    );

    return _ShowFocusMatches(
      values: values,
      root: root,
      load: load,
      suggestionKey: suggestionKey,
    ).run(context);
  }
}

/// Matches at or above this confidence (the server's 0–1 relevance score) are
/// pre-checked in the review step; weaker ones are left for the user to opt in.
/// The server already drops anything below 0.5, so this splits the "almost
/// certainly belongs" matches from the "might belong" ones.
const double _strongMatchScore = 0.75;

/// One matched thread surfaced in the focus-creation review step.
class _FocusMatch {
  const _FocusMatch({
    required this.threadId,
    required this.title,
    required this.score,
    this.thread,
  });
  final String threadId;
  final String title;

  /// Server relevance score (0–1). Drives whether the row is pre-checked.
  final double score;

  /// The hydrated thread from the local store, when it could be loaded. Drives
  /// the rich [ThreadSummary] row; falls back to [title] when null.
  final Thread? thread;

  /// Whether this match is confident enough to be checked by default.
  bool get isStrong => score >= _strongMatchScore;
}

/// Step 2 of [NewFocus]: review the threads that match the description. Pushed
/// as a nested modal by [_FindMatchingThreads], so the form header shows a Back
/// button and Esc returns to step 1 to edit the description and search again.
/// Shown immediately in a loading state; [_MatchingProgress] refreshes it into
/// the review UI once [load] completes.
class _ShowFocusMatches extends ShowForm {
  _ShowFocusMatches({
    required Map<String, dynamic> values,
    required Priority root,
    required _MatchLoadState load,
    String? suggestionKey,
  }) : super(
         title: 'Add a focus',
         icon: PlotIcon.add,
         form: (ctx) => _buildFocusMatchesForm(
           ctx,
           values: values,
           root: root,
           load: load,
           suggestionKey: suggestionKey,
         ),
       );
}

Future<FormData> _buildFocusMatchesForm(
  BuildContext context, {
  required Map<String, dynamic> values,
  required Priority root,
  required _MatchLoadState load,
  String? suggestionKey,
}) async {
  Future<List<StaticFormGroup>> buildGroups() async {
    final result = load.result;

    // Still loading: cycling progress, no Create button yet (Back/Esc returns
    // to step 1).
    if (result == null) {
      return [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'matching_progress',
              builder: (ctx) => _MatchingProgress(load: load),
            ),
          ],
        ),
      ];
    }

    // Loaded: review UI (failure / empty / matches) + Create button.
    final matches = result.matches;
    return [
      StaticFormGroup(
        items: [
          if (result.failed)
            FormInfo(
              key: 'match_failed',
              text:
                  'We couldn’t check for matching threads just now. Create the '
                  'focus and file threads into it as they come in.',
            )
          else if (matches.isEmpty)
            FormInfo(
              key: 'no_matches',
              text:
                  'No matching threads found yet. Create the focus and file '
                  'threads into it as they come in.',
            )
          else ...[
            FormInfo(
              key: 'matches_hint',
              text: matches.any((m) => m.isStrong)
                  ? 'Plot checked the threads it’s confident belong here. Check '
                        'any others that fit, and uncheck any that don’t.'
                  : 'These threads might belong in this focus. Check the ones '
                        'that fit.',
            ),
            for (final m in matches)
              FormToggle(
                key: 'match_${m.threadId}',
                label: m.title,
                content: m.thread != null
                    ? ThreadSummary(thread: m.thread!)
                    : null,
                initialValue: m.isStrong,
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
    ];
  }

  return FormData(
    title: 'Add a focus',
    groups: await buildGroups(),
    onRefresh: buildGroups,
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
    // Only strong matches the user actively unchecked are a confident negative.
    // Weak matches were unchecked by default (opt-in), so leaving them off
    // carries no signal — recording them would teach the classifier to reject
    // borderline-but-fine threads.
    final rejected = <String>[];
    for (final m in matches) {
      if (selections['match_${m.threadId}'] == true) {
        selected.add(m.threadId);
      } else if (m.isStrong) {
        rejected.add(m.threadId);
      }
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

    // Record the rejected strong matches as negative examples for future
    // matching.
    if (rejected.isNotEmpty) {
      try {
        await api.post<dynamic>(
          '/sync/priorities/negatives',
          body: {
            'negatives': [
              for (final id in rejected)
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
          final initialRole = await _resolveInitialRole(p.roleId);

          final colorField = FormSelect<ThemeColor>(
            key: 'color',
            label: 'Color',
            initialValue:
                p.color ?? initialRole?.displayColor ?? const ThemeColor(0),
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
          );
          final roleField = _roleSelect(
            initialRole: initialRole,
            colorField: colorField,
          );

          // The FYI focus is otherwise an ordinary focus, but its name and icon
          // are fixed ("FYI" / newspaper) and its role can't change (one FYI per
          // role, enforced by `unique (role_id) where is_fyi`). So its edit form
          // collects only the colour; name/icon/role stay as-is.
          final fyi = p.isFyi;

          return FormData(
            title: 'Edit focus',
            groups: [
              StaticFormGroup(
                items: [
                  if (!fyi) roleField,
                  if (!fyi)
                    FormTextInput(
                      key: 'title',
                      label: 'Focus name',
                      initialValue: p.title,
                      required: true,
                    ),
                  if (!fyi) _focusIconSelect(initial: p.icon ?? 'bullseyePointer'),
                  colorField,
                  FormButton(
                    key: 'save',
                    isPrimary: true,
                    buildCommand: (values) {
                      final color = values['color'] as ThemeColor?;
                      if (fyi) {
                        // FYI: name + icon + role are fixed; only colour edits.
                        return EditPriority(
                          Future.value(p.copyWith(color: Value(color))),
                        );
                      }
                      final title = values['title'] as String;
                      final icon = values['icon'] as String?;
                      final role = values['role'] as Role?;
                      // Focuses are team-agnostic: no team field. Per-focus
                      // default sharing is gone — the two-step target picker
                      // drives a thread's roster and team scope instead.
                      // Setting role_id fires the server's
                      // `apply_role_change_to_focus` trigger (follow-if-matching).
                      return EditPriority(
                        Future.value(
                          p.copyWith(
                            title: title,
                            color: Value(color),
                            icon: Value(icon),
                            roleId: role != null
                                ? Value(role.id)
                                : const Value.absent(),
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
    final inboxId = Priority.defaultInbox(priorities)?.id;
    Priority? root;
    final focuses = <Priority>[];
    for (final p in priorities) {
      if (p.id == inboxId) {
        root = p;
      } else if (p.id != source.id) {
        focuses.add(p);
      }
    }
    final commands = <Command>[
      ...focuses.map((target) => MergeFocus(source, target)),
      if (root != null && source.id != root.id) MergeFocus(source, root),
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

    // Hide the source focus immediately. The background merge below archives
    // it server-side and Priority.pull() lands that — but waiting for the
    // round-trip leaves the merged-away focus lingering in the sidebar, the
    // noticeable delay this addresses. Archiving it in the local store now
    // drops it from the sidebar the instant we navigate (Priority.watch
    // filters archived focuses). This is idempotent with the server merge:
    // merge_priority re-files the source's threads regardless of its archived
    // state, and its own archive is a no-op once the focus is archived, so
    // racing the optimistic archive against the merge is safe.
    try {
      await source.copyWith(archivedAt: Value(DateTime.now())).save();
    } catch (e, stackTrace) {
      // The optimistic hide is a nicety; never let a local write failure
      // block the merge or the navigation to the destination focus.
      Tracker.captureException(e, stackTrace);
    }

    // Merge in the background so the modal closes and we navigate to the
    // destination focus immediately. The server endpoint re-files every
    // filing from the source onto the target in one statement and archives
    // the source — transactionally, and crucially WITHOUT the per-thread
    // saves of the old client loop, each of which the API treated as an
    // explicit user filing (classifier training signal + a retroactive
    // reclassify sweep, which on a large workspace re-classified everything
    // and overwhelmed sync). The pulls afterwards land the re-filed threads
    // and the archived source in the local store; the destination feed fills
    // in live via Drift streams.
    unawaited(() async {
      try {
        await api.post<Map<String, dynamic>>(
          '/sync/priorities/merge',
          body: {
            'source_priority_id': source.id.toString(),
            'target_priority_id': target.id.toString(),
          },
        );
        await Priority.pull();
        await Thread.pull();
      } on NetworkException {
        // Offline: fall back to the local per-thread re-file loop so the
        // merge still completes and syncs when a connection returns.
        await _mergeFocusLocally(source, target);
      } catch (e, stackTrace) {
        Tracker.captureException(e, stackTrace);
        await _mergeFocusLocally(source, target);
      }
    }());

    // Always follow the threads to the destination focus. The source is being
    // archived, so there is nothing to stay on.
    return CommandRoute(
      PriorityRoute(priorityIdString: target.id.toShortString()),
    );
  }
}

/// Offline fallback for [MergeFocus]: the original client-side merge loop.
///
/// Re-files every thread filed under the source — including archived threads
/// and drafts — so nothing is stranded under the archived source, then
/// archives the source. Each thread save() syncs the re-filing when a
/// connection returns (the mechanism MoveToPriority relies on).
///
/// Non-transactional: a failure mid-loop leaves a partial re-file with the
/// source NOT archived (archiving happens after the loop). The server
/// endpoint used on the happy path has neither problem — prefer it whenever
/// the API is reachable, not least because the server treats each per-thread
/// save as an explicit user filing (classifier training + reclassify sweep).
Future<void> _mergeFocusLocally(Priority source, Priority target) async {
  try {
    final threads = await Thread.get(
      priorityId: source.id,
      archived: null,
      draft: null,
    );
    for (final thread in threads) {
      await thread.copyWith(priority: target).save();
    }
    await source.copyWith(archivedAt: Value(DateTime.now())).save();
  } catch (e, stackTrace) {
    Tracker.captureException(e, stackTrace);
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
  // Every role's Inbox ([isInbox], including the Personal role's, which is the
  // top-level focus) is auto-managed and not editable/removable: its name is
  // locked to "Inbox" and its colour/notifications follow the role, so it
  // offers no Edit (the Role field there could try to re-home an Inbox, which
  // the server's `unique (role_id) where is_inbox` rejects) and no Archive/Merge.
  // The FYI focus ([isFyi]) keeps Edit (colour only — name/icon/role are fixed
  // there) and Archive, but has notifications permanently off, so it offers no
  // notification settings.
  if (!priority.isInbox) EditPriorityCommand(priority),
  if (!priority.isFyi) ShowEarlyNotificationsSettings(priority),
  // Scheduled sending: per-focus send window (kept as its own entry so
  // notifications and send windows stay conceptually distinct). The FYI
  // focus is inbound-only, so it offers none.
  if (!priority.isFyi) ShowSendWindowSettings(priority),
  ShowTimeLog(priority),
  if (!priority.isInbox) ...archiveOrMergeCommands(priority),
];

/// The destructive slot on a focus menu. An archived focus offers Un-archive.
/// An active focus with threads offers "Merge into…" (move its threads
/// elsewhere, then archive) followed by a plain Archive (hide the focus, leave
/// its threads filed where they are — still findable via search/filter). An
/// active empty focus offers a one-click Archive. The Inbox (root) never
/// reaches here (gated by the caller).
List<Command> archiveOrMergeCommands(Priority priority) {
  if (priority.archivedAt != null) return [TogglePriorityArchived(priority)];
  if (priority.hasThreads) {
    return [MergeFocusInto(priority), TogglePriorityArchived(priority)];
  }
  return [TogglePriorityArchived(priority)];
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
  if (context != null) ToggleArchived.fromContext(context),
  NewThread(),
  OpenNextThread(),
  OpenPreviousThread(),
  if (nowState != null) ...timerCommands(nowState),
];

List<StaticCommandGroup> priorityCommandGroups(Priority priority) => [
  StaticCommandGroup(
    title: priority.isInbox ? 'Inbox' : 'Focus: ${priority.title}',
    commands: priorityCommands(priority),
  ),
];

List<StaticCommandGroup> currentPriorityCommandGroups(
  Priority priority, {
  BuildContext? context,
  NowState? nowState,
}) => [
  StaticCommandGroup(
    title: priority.isInbox ? 'Inbox' : 'Focus: ${priority.title}',
    commands: currentPriorityCommands(
      priority,
      context: context,
      nowState: nowState,
    ),
  ),
];

/// Toggle archived visibility everywhere with a single command: archived
/// focuses in the focus list, plus archived threads and notes inside the open
/// focus/thread.
///
/// Backed by the single persisted `showAllPriorities` flag on
/// [LocalPreferencesBloc] (always in scope, provided app-wide). [PriorityBloc]
/// and [ThreadBloc] seed their own `showArchived` from this flag at
/// construction and react to its changes, so toggling here flips archived
/// visibility consistently across every view without touching those blocs
/// directly.
class ToggleArchived extends Command {
  ToggleArchived({required this.showingArchived})
    : super(
        title: showingArchived ? 'Hide archived items' : 'Show archived items',
        subtitle: showingArchived
            ? 'Hide archived focuses, threads and notes'
            : 'Show archived focuses, threads and notes',
        eventObject: EventObject.archived,
        eventAction: EventAction.viewed,
        icon: PlotIcon.archived,
      );

  /// Reads the current archived-visibility flag from [LocalPreferencesBloc]
  /// to title the command.
  factory ToggleArchived.fromContext(BuildContext context) {
    final showing = context
        .read<LocalPreferencesBloc>()
        .state
        .showAllPriorities;
    return ToggleArchived(showingArchived: showing);
  }

  final bool showingArchived;

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

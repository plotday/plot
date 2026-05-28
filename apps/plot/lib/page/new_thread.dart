import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/state/priority.dart';

import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/command/command.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/page/priority.dart'
    show ActivityPanelControllerProvider, PriorityShortcutsProviderState;
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/link_type_copy.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/url_title.dart' show fetchUrlMetadata;
import 'package:plot/analytics/tracker.dart';
import 'logging.dart';

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
  });

  final String? startTime;
  final String? endTime;
  final int? duration; // Duration in minutes
  final String? priorityId;
  final String? sharedUrl;

  @override
  State<NewThreadPage> createState() => NewThreadPageState();
}

class NewThreadPageState extends State<NewThreadPage> {
  final GlobalKey<NoteEditorState> _threadEditorKey =
      GlobalKey<NoteEditorState>();
  final GlobalKey<TitleComposeFieldState> _titleFieldKey =
      GlobalKey<TitleComposeFieldState>();

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

  // Selected twist for chat mode
  TwistInstance? _selectedTwist;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

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
        onSearchClosed: () {},
        tags: const [],
        filter: const [],
        isNewThread: true,
      );
      _provider?.registerActivityPanel(
        editorFocusCallback: () => _threadEditorKey.currentState?.focus(),
      );
    });

    // Apply query parameters to draft
    if (!_hasAppliedQueryParams) {
      _hasAppliedQueryParams = true;
      _initializeDraft();
    }
  }

  /// Adds the current draft to [ThreadsBase.autoFileIds] when the user is in
  /// the root context and hasn't explicitly picked or remembered a priority.
  /// Wraps the static-set mutation in setState so the priority chip rebuilds.
  void _applyDefaultAutoFile() {
    final bloc = context.read<PriorityBloc>();
    final hasExplicitPriority =
        widget.priorityId != null || bloc.newThreadDefaultPriority != null;
    if (bloc.state.context.root && !hasExplicitPriority) {
      final draftId = bloc.state.draft.id.toString();
      if (ThreadsBase.autoFileIds.add(draftId)) {
        setState(() {});
      }
    }
  }

  /// Sequences query parameter application and post-load setup.
  /// Async because _applyQueryParametersToDraft awaits DB lookups.
  Future<void> _initializeDraft() async {
    await _applyQueryParametersToDraft();
    if (!mounted) return;

    // Auto-organize is ON by default only in the root ("Everything") priority
    // context and when the user has not explicitly picked or carried over a
    // priority. In a non-root context, the default is the most recent picker
    // priority (session-remembered) or the current context priority — never
    // auto — so the thread goes where the user is working.
    _applyDefaultAutoFile();

    // Load available connection create-targets for the connection chip row.
    await _loadConnections();
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

    // Share intent: add the shared URL as a link action on the draft note.
    if (widget.sharedUrl != null && mounted) {
      final currentNote = bloc.state.draftNote;
      final existingActions = currentNote.actions ?? const <UserAction>[];
      final alreadyPresent = existingActions.any(
        (a) => a is ExternalUserAction && a.url == widget.sharedUrl,
      );
      if (!alreadyPresent) {
        log.info('[NewThreadPage] Adding shared URL as ExternalUserAction');
        final updatedNote = currentNote.copyWith(
          actions: [
            ...existingActions,
            ExternalUserAction(
              title: widget.sharedUrl!,
              url: widget.sharedUrl!,
            ),
          ],
        );
        await bloc.updateDraft(bloc.state.draft, note: updatedNote);
        // Fire-and-forget metadata fetch — when it returns we replace the
        // action so the link chip shows the page title and the thread
        // (created via AddThreadWithLink on submit) gets the favicon.
        unawaited(_resolveSharedUrlMetadata(widget.sharedUrl!));
      }
    }
  }

  /// Looks up `<title>` and favicon for [url] and updates the matching
  /// `ExternalUserAction` in the draft. Matches by URL — the draft note may
  /// have been mutated while the request was in flight, so identity isn't
  /// safe.
  Future<void> _resolveSharedUrlMetadata(String url) async {
    final meta = await fetchUrlMetadata(url);
    if (!mounted) return;
    if (meta.title == null && meta.favicon == null) return;
    final bloc = _priorityBloc;
    if (bloc == null) return;
    final note = bloc.state.draftNote;
    final actions = note.actions ?? const <UserAction>[];
    final idx = actions.indexWhere(
      (a) => a is ExternalUserAction && a.url == url,
    );
    if (idx < 0) return;
    final existing = actions[idx] as ExternalUserAction;
    // If the user already typed a custom title or the metadata didn't
    // upgrade either field, don't overwrite.
    final shouldUpdateTitle = meta.title != null && existing.title == url;
    final shouldUpdateFavicon =
        meta.favicon != null && existing.favicon == null;
    if (!shouldUpdateTitle && !shouldUpdateFavicon) return;
    final replacement = ExternalUserAction(
      title: shouldUpdateTitle ? meta.title! : existing.title,
      url: existing.url,
      favicon: shouldUpdateFavicon ? meta.favicon : existing.favicon,
    );
    final next = [...actions]..[idx] = replacement;
    await bloc.updateDraft(
      bloc.state.draft,
      note: note.copyWith(actions: next),
    );
  }

  @override
  void dispose() {
    // Unregister from the focus coordination provider using saved reference
    _provider?.unregisterActivityPanel();
    // Unregister from thread header notifier
    _headerNotifier?.unregister();
    // Clear middle panel preference when leaving NewThreadPage
    LayoutBloc.instance?.preferMiddle = false;
    super.dispose();
  }

  Future<void> _selectPriority(
    BuildContext context,
    PriorityState state,
  ) async {
    final isAuto = ThreadsBase.autoFileIds.contains(state.draft.id.toString());
    final result = await SelectModal.open<PriorityChoice>(
      context,
      items: (search) async {
        final priorities = await Priority.get(order: PriorityOrder.nested);
        final query = search?.trim().toLowerCase() ?? '';
        final includeAuto = query.isEmpty || 'auto'.contains(query);
        final filteredPriorities = priorities
            .where((p) => query.isEmpty || p.matchesSearch(search ?? ''))
            .map<PriorityChoice>(PickedPriorityChoice.new)
            .toList();
        return [
          SelectGroup<PriorityChoice>(
            title: null,
            items: [
              if (includeAuto) const AutoOrganizeChoice(),
              ...filteredPriorities,
            ],
          ),
        ];
      },
      itemBuilder: (choice, _) => switch (choice) {
        AutoOrganizeChoice() => ListTile(
          icon: PlotIcon.sparkles,
          title: 'Auto-organize',
        ),
        PickedPriorityChoice(:final priority) => ListTile(
          body: PriorityLabel(priority: priority),
        ),
      },
      selectedValue: isAuto
          ? const AutoOrganizeChoice()
          : PickedPriorityChoice(state.draft.priority),
      prompt: 'Select priority',
      onAdd: (ctx) => createPriorityInline(
        ctx,
        parent: state.draft.priority,
      ).then((p) => p == null ? null : PickedPriorityChoice(p)),
    );
    if (!result.present) return;
    final picked = result.value;
    if (!mounted) return;
    if (picked is AutoOrganizeChoice) {
      await _switchToAuto();
    } else if (picked is PickedPriorityChoice) {
      await _switchToPriority(picked.priority);
    }
  }

  Future<void> _switchToAuto() async {
    final bloc = context.read<PriorityBloc>();
    final draft = bloc.state.draft;
    setState(() {
      ThreadsBase.autoFileIds.add(draft.id.toString());
    });
    // Auto-filed threads live in the root priority until the server re-files.
    final root = await Priority.getDefault();
    if (!mounted) return;
    if (draft.priority.id != root.id) {
      final updated = _applyChainDefaults(draft, root);
      await bloc.updateDraft(updated);
    }
  }

  Future<void> _switchToPriority(Priority priority) async {
    final bloc = context.read<PriorityBloc>();
    final draft = bloc.state.draft;
    setState(() {
      ThreadsBase.autoFileIds.remove(draft.id.toString());
    });
    if (priority.id != draft.priority.id) {
      final updated = _applyChainDefaults(draft, priority);
      await bloc.updateDraft(updated);
    }
    bloc.setNewThreadDefaultPriority(priority);
  }

  /// Swap the draft's priority and merge in the new chain's default
  /// contacts/groups/invite-emails. Treats members of the OLD priority
  /// chain's defaults that are still on the draft as seeded (drops them),
  /// keeps everything else as user-added, then unions in the NEW chain's
  /// defaults. See C2 merge semantics in the design.
  Thread _applyChainDefaults(Thread draft, Priority newPriority) {
    final oldPriority = draft.priority;
    final oldContactDefaults = oldPriority.inheritedDefaultSharedContacts
        .toSet();
    final oldGroupDefaults = oldPriority.inheritedDefaultSharedGroups.toSet();
    final oldEmailDefaults = oldPriority.inheritedDefaultSharedInviteEmails
        .toSet();

    final newContactDefaults = newPriority.inheritedDefaultSharedContacts;
    final newGroupDefaults = newPriority.inheritedDefaultSharedGroups;
    final newEmailDefaults = newPriority.inheritedDefaultSharedInviteEmails;

    List<T> merge<T>(List<T> current, Set<T> oldDefaults, List<T> newDefaults) {
      final userAdded = current.where((e) => !oldDefaults.contains(e)).toList();
      final seen = <T>{...userAdded};
      final result = [...userAdded];
      for (final e in newDefaults) {
        if (seen.add(e)) result.add(e);
      }
      return result;
    }

    final mergedContacts = merge(
      draft.contacts,
      oldContactDefaults,
      newContactDefaults,
    );
    final mergedGroups = merge(
      draft.groups,
      oldGroupDefaults,
      newGroupDefaults,
    );
    final mergedEmails = merge(
      draft.inviteEmails,
      oldEmailDefaults,
      newEmailDefaults,
    );

    return draft.copyWith(
      priority: newPriority,
      contacts: Value(mergedContacts.isEmpty ? null : mergedContacts),
      groups: Value(mergedGroups.isEmpty ? null : mergedGroups),
      inviteEmails: Value(mergedEmails.isEmpty ? null : mergedEmails),
    );
  }

  /// Routes a ConnectionChoice from the modal/dropdown into the draft note.
  /// Plot thread clears any CreateLinkUserAction; a target replaces it.
  Future<void> _applyConnectionChoice(ConnectionChoice choice) async {
    final bloc = _priorityBloc;
    if (bloc == null) return;
    final note = bloc.state.draftNote;
    final actions = List<UserAction>.from(note.actions ?? const []);
    actions.removeWhere((a) => a is CreateLinkUserAction);
    final action = choice.toUserAction();
    if (action != null) actions.add(action);
    // Pass the list directly (even when empty) — Note.copyWith treats a
    // null `actions` arg as "keep existing", so the prior CreateLinkUserAction
    // would survive when the user picks "Plot thread".
    await bloc.updateDraft(
      bloc.state.draft,
      note: note.copyWith(actions: actions),
    );
  }

  Future<void> _openConnectionPicker() async {
    final picked = await ConnectionPickerModal.open(context);
    if (picked == null || !mounted) return;
    await _applyConnectionChoice(picked);
  }

  ConnectionChoice _resolveActiveConnectionChoice(PriorityState state) {
    final active = state.draftNote.actions
        ?.whereType<CreateLinkUserAction>()
        .firstOrNull;
    if (active == null) return ConnectionChoice.plotThread;
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
    return ConnectionChoice.plotThread;
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
    final roleConfigs = _activeLinkTypeConfig?.contactRoles;
    await context.run(
      PickDraftThreadShared(
        thread: priorityBloc.state.draft,
        dmTwistInstanceId: dmTwistInstanceId,
        isAddressMode: isAddress,
        roleConfigs: roleConfigs,
        onUpdate: (thread) async {
          if (!context.mounted) return;
          await priorityBloc.updateDraft(thread);
        },
      ),
    );
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

  void _selectTwist(TwistInstance twist) {
    setState(() => _selectedTwist = twist);
    final bloc = context.read<PriorityBloc>();
    bloc.updateDraftLocal(
      bloc.state.draft.copyWith(icon: Value('twist:${twist.twistId}')),
    );
    context.read<LocalPreferencesBloc>().recordMentionUsage(
      twist.id.toString(),
    );
  }

  String get _editorHint {
    if (_selectedTwist != null) return "Chat with ${_selectedTwist!.name}";
    final cfg = _activeLinkTypeConfig;
    if (cfg != null) return composerHintForNewThread(cfg);
    return 'Start a thread';
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
  }

  void _onChatSubmitted() {
    if (_selectedTwist != null) {
      context.read<LocalPreferencesBloc>().recordMentionUsage(
        _selectedTwist!.id.toString(),
      );
    }
    // Clear global search so the new thread is visible in the list
    _provider?.tryCloseSearch();
  }

  Widget _buildComposeSurface(BuildContext context, PriorityState state) {
    final isAuto = ThreadsBase.autoFileIds.contains(state.draft.id.toString());
    final activeChoice = _resolveActiveConnectionChoice(state);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PriorityComposeField(
          currentPriority: state.draft.priority,
          isAuto: isAuto,
          openModal: () => _selectPriority(context, state),
        ),
        ConnectionComposeField(
          activeChoice: activeChoice,
          openModal: _openConnectionPicker,
        ),
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
        return BlocListener<PriorityBloc, PriorityState>(
          // Re-apply the default auto-file flag when the draft id changes
          // (chain drafts load async after mount or after submit) or when the
          // context changes (a PrioritiesPage click can mount NewThreadPage
          // with a stale PriorityBloc context before setPriority emits the
          // new root context — without listening for context we'd never
          // re-mark the draft as Auto on the way back to root).
          listenWhen: (prev, curr) =>
              prev.draft.id != curr.draft.id ||
              prev.context.id != curr.context.id,
          listener: (context, _) {
            if (!_hasAppliedQueryParams) return;
            _applyDefaultAutoFile();
          },
          child: BlocBuilder<PriorityBloc, PriorityState>(
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
              final isViewerMode = state.draft.priority.isViewer;

              if (state.draft.priority.isTwistDev) {
                return Scaffold(
                  translucent: true,
                  scrollable: false,
                  childPad: false,
                  body: Center(
                    child: Text(
                      'Select a thread',
                      style: context.theme.typography.sm.copyWith(
                        color: context.theme.plotColors.muted,
                      ),
                    ),
                  ),
                );
              }

              return PopScope(
                canPop: false,
                onPopInvokedWithResult: (didPop, result) {
                  if (!didPop) {
                    if (ModalProvider.tryDismissTopModal(context)) return;
                    final provider = ActivityPanelControllerProvider.maybeOf(
                      context,
                    );
                    if (provider != null && provider.tryCloseSearch()) return;
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
                    body: LayoutBuilder(
                      builder: (context, constraints) {
                        // Single panel mode: editor at bottom, edge-to-edge
                        if (!layoutState.multiPanel) {
                          return Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: context.contentPaddingH,
                            ),
                            child: FocusTraversalGroup(
                              policy: WidgetOrderTraversalPolicy(),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!isViewerMode)
                                    _buildComposeSurface(context, state),
                                  if (!isViewerMode)
                                    SizedBox(height: context.theme.spacing.md),
                                  Flexible(
                                    child: EditableArea(
                                      padding: false,
                                      position: EditableAreaPosition.bottom,
                                      flushToBottom: true,
                                      builder: (context, _) => Focus(
                                        canRequestFocus: false,
                                        skipTraversal: true,
                                        onKeyEvent: _handleEditorShiftTab,
                                        child: NoteEditor(
                                          key: _threadEditorKey,
                                          bodyOnly: true,
                                          draft: state.draftNote,
                                          thread: state.draft,
                                          onDraftChanged: _handleDraftChanged,
                                          flushToBottom: true,
                                          showScheduleActions: false,
                                          hint: state.draft.priority.isPlotApp
                                              ? 'Ask for help or share feedback'
                                              : _editorHint,
                                          additionalMentions: _twistMentions,
                                          onSubmitted: _onChatSubmitted,
                                          submitValidator: _validateDmSubmit,
                                          viewerMode: isViewerMode,
                                          selectedTwist: _selectedTwist,
                                          onTwistSelected: _selectTwist,
                                          onNavigateToThread: (thread) {
                                            context.run(
                                              ChangeCurrentThread(thread),
                                            );
                                          },
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
                          padding: const EdgeInsets.symmetric(horizontal: 20),
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
                                        if (!isViewerMode)
                                          _buildComposeSurface(context, state),
                                        if (!isViewerMode)
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
                                              onKeyEvent: _handleEditorShiftTab,
                                              child: NoteEditor(
                                                key: _threadEditorKey,
                                                bodyOnly: true,
                                                draft: state.draftNote,
                                                thread: state.draft,
                                                onDraftChanged:
                                                    _handleDraftChanged,
                                                flushToBottom: false,
                                                showScheduleActions: false,
                                                hint:
                                                    state
                                                        .draft
                                                        .priority
                                                        .isPlotApp
                                                    ? 'Ask for help or share feedback'
                                                    : _editorHint,
                                                additionalMentions:
                                                    _twistMentions,
                                                onSubmitted: _onChatSubmitted,
                                                submitValidator:
                                                    _validateDmSubmit,
                                                viewerMode: isViewerMode,
                                                selectedTwist: _selectedTwist,
                                                onTwistSelected: _selectTwist,
                                                onNavigateToThread: (thread) {
                                                  context.run(
                                                    ChangeCurrentThread(thread),
                                                  );
                                                },
                                                autofocus: !isMobilePlatform(),
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
              );
            },
          ),
        );
      },
    );
  }

  /// Intercepts Shift+Tab bubbling up from the focused note editor and
  /// sends focus back to the title field. SuperEditor doesn't consume Tab
  /// outside its mention popover, so the unhandled key reaches this Focus
  /// ancestor; we only act on Shift+Tab so plain Tab inside the editor
  /// remains available (currently the default focus traversal also leaves
  /// the editor, which is fine).
  KeyEventResult _handleEditorShiftTab(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
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
  /// NewThreadPage: share (contacts). Note-level shortcuts are handled
  /// inside NoteEditor. Priority, title, and schedule are set via the
  /// priority chip / title input or after the thread is created.
  Map<ShortcutActivator, VoidCallback> _buildThreadShortcuts(
    BuildContext context,
    PriorityState state,
  ) {
    final isViewerMode = state.draft.priority.isViewer;
    if (isViewerMode) return const {};

    return {
      // ⌘⇧S — share (contacts)
      platformSingleActivator(LogicalKeyboardKey.keyS, shift: true): () {
        _openSharedPicker(context);
      },
      // ⌘⇧P (⌘⌥⇧P on web) — change priority
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

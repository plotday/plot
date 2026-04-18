# Default tab selection (Agenda vs Activity) in multi-panel mode

## Goal

Switch the default `PriorityTab` from Agenda to Activity in two situations:

1. The current priority (and its descendants) has no agenda items.
2. A thread is opened that is not part of the current priority's agenda.

Both rules only ever switch *to* Activity. They never auto-switch back to Agenda; once Activity is shown, the user must toggle back manually. This keeps the user's manual choice sticky.

## Current behavior

- `PriorityTabNotifier` (`apps/plot/lib/page/priority.dart:31`) extends `ValueNotifier<PriorityTab>` and defaults to `PriorityTab.agenda`. A single instance lives on `PrioritiesShell` (`apps/plot/lib/widget/priorities_shell.dart:26`) and is exposed through `PriorityTabProvider`.
- The notifier is sticky across priority navigations.
- Existing override: `_PriorityPageState.didChangeDependencies` flips to `activityFeed` for `isActivityOnly` priorities (`apps/plot/lib/page/priority.dart:776–786`).
- `PriorityState.agendaItems` populates asynchronously after `setPriority`; there is no `agendaLoaded` flag today (only `activityFeedLoaded`).
- `ChangeCurrentThread` (`apps/plot/lib/command/thread.dart:62`) sets the thread on `PriorityBloc` and routes; it does not touch the tab notifier.

## Design

### 1. Add `agendaLoaded` to `PriorityState`

Mirror `activityFeedLoaded`:

- Add `bool agendaLoaded = false` field, constructor arg, `copyWith` arg, and props entry in `apps/plot/lib/state/priority_state.dart`.
- Reset to `false` in `setPriority` alongside the existing reset of `agendaItems` (`apps/plot/lib/state/priority.dart:794`).
- Set to `true` on the first emit from the agenda stream listener inside `_loadAgenda` (`apps/plot/lib/state/priority.dart:1568`).

This gives the auto-switch a reliable "agenda has been read at least once" signal so we don't flip to Activity merely because items haven't streamed in yet.

### 2. Auto-switch listener in `PriorityWrapper`

Add a `BlocListener<PriorityBloc, PriorityState>` inside `PriorityBlocProvider` in `PriorityWrapper.wrappedRoute` (`apps/plot/lib/page/priority.dart:91`). This wrapper is shared by single-panel and multi-panel layouts, so the rule applies in both — but the user only asked about multi-panel. Since the tab notifier is also used by mobile (via PriorityOnlyPage), applying it everywhere is consistent and harmless.

`listenWhen` fires when any of the following changes:
- Priority context id (`prev.context.id != current.context.id`)
- Agenda first becomes loaded (`!prev.agendaLoaded && current.agendaLoaded`)
- Thread becomes non-null or changes (`prev.thread?.id != current.thread?.id && current.thread != null`)

`listener` body:
```dart
if (!state.agendaLoaded) return;
if (state.context.isActivityOnly) return; // existing flow handles this
final notifier = PriorityTabProvider.maybeOf(context);
if (notifier == null || notifier.value != PriorityTab.agenda) return;

final agendaIsEmpty = state.agendaItems.isEmpty;
final thread = state.thread;
final threadInAgenda = thread == null ||
    state.agendaItems.any((item) => item.when(
          header: (_) => false,
          activity: (a) => a.thread.id == thread.id,
        ));

if (agendaIsEmpty || !threadInAgenda) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    notifier.value = PriorityTab.activityFeed;
  });
}
```

Notes:
- Defer to a post-frame callback (consistent with the existing tab-notifier writes in this file) to avoid setState-during-build in `PriorityTabProvider` listeners.
- The existing `_PriorityPageState._onTabNotifierChanged` will pick the change up and rebuild the page on the new tab.
- The listener does not fire when the user manually toggles tabs (no PriorityBloc state change), so manual choices win.

### Why not also touch `ChangeCurrentThread`?

The bloc listener already covers thread-open transitions (`prev.thread?.id != current.thread?.id`). Putting the rule in one place keeps the timing right when a `/t/` URL arrives before the agenda has loaded — the listener naturally re-evaluates when `agendaLoaded` flips true.

## Out of scope

- No change to `_PriorityPageState`'s existing `isActivityOnly` override.
- No persistence of the auto-switched tab (notifier remains in-memory).
- No new shortcuts or UI affordances.

## Files touched

- `apps/plot/lib/state/priority_state.dart` — add `agendaLoaded`.
- `apps/plot/lib/state/priority.dart` — reset on `setPriority`, set on first agenda emit.
- `apps/plot/lib/page/priority.dart` — add `BlocListener` in `PriorityWrapper`.

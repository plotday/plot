# Layout and Routing Architecture

This document describes the layout and routing system for the Plot Flutter app, including expected behaviors, implementation details, and guidance for making changes.

## Overview

The app uses a responsive layout system that adapts between **single-panel** (mobile/narrow) and **multi-panel** (desktop/wide) modes. The layout is managed by `LayoutBloc` and routing is handled by AutoRoute.

## Layout Modes

### Single-Panel Mode (Mobile/Narrow Windows)

**Triggers:** Window width < threshold for multi-panel support

**Behavior:**

- Bottom navigation bar with five persistent tab stacks managed by `AutoTabsRouter`:
  - **Tab 0 (Priorities):** Shows `PrioritiesPage` — the full focus list; bottom-nav label "Focus"
  - **Tab 1 (Agenda):** Shows `AgendaPage` — only present when a calendar connection exists
  - **Tab 2 (Activity):** Per-priority thread feed (`PriorityPage`), threads (`ThreadPage`), and new-thread (`/new`); this is the working-area stack (also used by multi-panel)
  - **Tab 3 (Search):** Shows `SearchPage`; opening a search result pushes a `PriorityRoute` + `ThreadRoute` onto this stack, so Back returns to the results
  - **Tab 4 (More):** Shows `MoreRoute` — settings rendered as a page
- **Default tab:** Priorities (index 0, `homeIndex: _kTabPriorities`)
- The Activity tab has no dedicated bottom-nav button. Navigation into it happens via the "New" slot (which uses the Activity stack) or via priority/thread taps from Focuses or Agenda.
- Agenda slot is conditional — when no calendar connection exists it is hidden and the remaining slots shift left; `navSlotsFor(hasCalendar:)` computes the display-order list at runtime.
- Bottom-nav visual slots (`NavSlot` enum): `focuses`, `agenda`, `newThread`, `search`, `more`

**Tab navigation — key rules:**

- Tapping a nav slot for a tab that is already active pops its inner stack to root (`_switchOrPopToRoot` / `stack.popUntilRoot()`). This is the standard "tap active tab = go home" idiom.
- Tapping **New** uses the Activity (tab 2) stack. `_openNewThread` decides between three cases:
  - `/new` is parked on the Activity stack while a different tab is showing → switch to Activity to **resume** the draft
  - Already viewing `/new` on the Activity tab → **reset** to step 1 (tap-active = start over)
  - No `/new` on the Activity stack → reset then push a fresh `NewThreadRoute`
- Bottom-nav tab switches are recorded as `markUrlStateForReplace` so the browser/Cmd+[ history does not grow a frame per tap.

**Bottom bar visibility:**

The bar is **hidden** on full-screen routes and **shown** on `/new` (even though `/new` is an inner Activity-tab route, it keeps the bar — it is a top-level tab conceptually). `_isFullScreenRoute` rules:

- `t/:id` (standalone thread) → always hidden
- Path ending in `/new` → always **shown** (returns `false`)
- `/p/:priorityId/:threadId` (3+ non-empty segments) → hidden
- All other paths (focus list, agenda, search, more, `/p/:priorityId` with 2 segments) → shown

**PriorityPage back button (single-panel):**

`PriorityPage` (the thread feed for a specific focus) renders a visible `←` back button. Tapping it (or performing the back gesture via `PopScope`) calls `returnFromPriorityToSourceTab`, which returns the user to whichever tab they came from (`PrioritiesShell.sourceTab`) — typically the focus list, but Agenda for deep-link arrivals.

**Widget Tree (Single-Panel):**

```
AutoTabsRouter (in PrioritiesShell, homeIndex=0)
├─ Tab 0: PrioritiesRoute → PrioritiesPage
├─ Tab 1: EmptyShellRoute("AgendaShell") → AgendaRoute → AgendaPage
├─ Tab 2: EmptyShellRoute("ActivityShell") [catch-all path '']
│          └─ PriorityRoute (at /p/:priorityId)
│             └─ PriorityWrapper → ResizablePanelLayout (panels hidden in single-panel)
│                └─ Right panel AutoRouter renders:
│                   ├─ PriorityOnlyRoute → PriorityOnlyPage → PriorityPage (initial route at '')
│                   ├─ NewThreadRoute → NewThreadPage (at 'new')
│                   └─ ThreadRoute → ThreadPage (at ':threadId')
├─ Tab 3: EmptyShellRoute("SearchShell") → SearchRoute → SearchPage
│          └─ (child) PriorityRoute (at /p/:priorityId)
│             └─ ThreadRoute (at ':threadId')  [search result opens here]
└─ Tab 4: EmptyShellRoute("MoreShell") → MoreRoute → MorePage
```

### Multi-Panel Mode (Desktop/Wide Windows)

**Triggers:** Window width ≥ threshold for multi-panel support

**Behavior:**

- No bottom navigation (tabs not visible)
- Up to 3 panels side-by-side:
  - **Left panel:** `PrioritiesPage` (toggleable, preserves state)
  - **Middle panel:** `PriorityPage` (toggleable, preserves state)
  - **Right panel:** `NewThreadPage` or `ThreadPage` (always visible)
- Right panel **always** has content in multi-panel mode
- When no thread is selected:
  - If middle panel is visible, `PriorityOnlyPage` detects this and automatically navigates to `NewThreadRoute`, showing `NewThreadPage` in the right panel
  - If middle panel is not visible, `PriorityOnlyPage` shows `PriorityPage` in the right panel
- In multi-panel mode, the active tab is forced to Activity (tab 2) if it is not already there; if the Activity stack is empty, it is seeded with the current `PriorityRoute`
- Panels can be toggled independently without affecting content
- Panel visibility is tracked in `LayoutBloc` state

**Widget Tree (Multi-Panel):**

```
AutoTabsRouter (in PrioritiesShell) — no visible tabs
└─ Tab 2 (Activity): EmptyShellRoute("ActivityShell")
   └─ PriorityRoute (at /p/:priorityId)
      └─ PriorityWrapper → ResizablePanelLayout
         ├─ Left: PrioritiesPage (if leftPanelVisible)
         ├─ Middle: PriorityPage (if middlePanelVisible)
         └─ Right: AutoRouter → Shows:
            ├─ PriorityOnlyRoute → PriorityOnlyPage (initial route)
            │  └─ If middlePanelVisible: LoadingPage + navigates to NewThreadRoute
            │  └─ If !middlePanelVisible: PriorityPage
            ├─ NewThreadRoute → NewThreadPage (after auto-navigation or manual)
            └─ ThreadRoute → ThreadPage (when thread selected)
```

## Route Hierarchy

```
AppShellRoute
└─ PrioritiesShellRoute (with AutoTabsRouter)
   ├─ PrioritiesRoute (Tab 0, at /priorities)
   │  └─ PrioritiesPage
   │
   ├─ EmptyShellRoute("AgendaShell") (Tab 1, at /agenda)
   │  └─ AgendaRoute → AgendaPage
   │
   ├─ EmptyShellRoute("ActivityShell") (Tab 2, catch-all at '')
   │  ├─ PriorityRoute (at /p/:priorityId)
   │  │  └─ PriorityWrapper → ResizablePanelLayout
   │  │     └─ Right panel AutoRouter:
   │  │        ├─ PriorityOnlyRoute (initial route, at '') → PriorityOnlyPage
   │  │        ├─ NewThreadRoute (at 'new') → NewThreadPage
   │  │        └─ ThreadRoute (at ':threadId') → ThreadPage
   │  ├─ ThreadLookupRoute (at /t/:threadId)
   │  └─ NotificationLandingRoute (at /n/:priorityId/:threadIds)
   │
   ├─ EmptyShellRoute("SearchShell") (Tab 3, at /search)
   │  ├─ SearchRoute (at '') → SearchPage
   │  └─ PriorityRoute (at /p/:priorityId)
   │     └─ ThreadRoute (at ':threadId') → ThreadPage [search result]
   │
   └─ EmptyShellRoute("MoreShell") (Tab 4, at /more)
      └─ MoreRoute (at '') → MorePage
```

**Key Points:**

- `PriorityRoute` wraps an `AutoRouter` (via `PriorityWrapper` / `AutoRouteWrapper`) that manages child routes in the right panel
- `PriorityOnlyRoute` is the initial/default route under `PriorityRoute`
- `PriorityOnlyPage` is **layout-aware**: it uses `BlocConsumer<LayoutBloc, LayoutState>` to:
  - Show `PriorityPage` when `middlePanelVisible` is false (single-panel mode or middle panel hidden)
  - Navigate to `NewThreadRoute` when `middlePanelVisible` is true (multi-panel mode with middle panel shown)
- `ResizablePanelLayout` always renders all three panel widgets (left, middle, right)
- Panel visibility is controlled by `LayoutBloc` state
- In single-panel mode, only the right panel (AutoRouter content) is shown; the left/middle panels are hidden
- In multi-panel mode, left and/or middle panels become visible alongside the right panel

## State Preservation

### AutoTabsRouter Always Active

**Critical:** `AutoTabsRouter` is **always** present in `PrioritiesShell`, even in multi-panel mode where tabs aren't visible.

**Why?** This ensures state is preserved when transitioning between single and multi-panel modes, and keeps each tab's navigation stack alive independently.

**Route Configuration:**

```dart
AutoTabsRouter(
  homeIndex: _kTabPriorities,  // 0
  routes: [
    PrioritiesRoute(),                        // Tab 0
    EmptyShellRoute("AgendaShell")(),         // Tab 1
    EmptyShellRoute("ActivityShell")(),       // Tab 2
    EmptyShellRoute("SearchShell")(),         // Tab 3
    EmptyShellRoute("MoreShell")(),           // Tab 4
  ],
)
```

**Tab index constants (in priorities_shell.dart):**

```dart
const int _kTabPriorities = 0;
const int _kTabAgenda    = 1;
const int _kTabActivity  = 2;
const int _kTabSearch    = 3;
const int _kTabMore      = 4;
```

**In multi-panel mode:**

- Tab index is forced to 2 (Activity tab) via a post-frame callback if it isn't already
- Tab navigation is disabled (no bottom nav rendered)
- All panels are rendered simultaneously via `ResizablePanelLayout`

**In single-panel mode:**

- User switches between tabs via the bottom nav
- Active tab determines which content is shown

### Layout State Transitions

**Single → Multi:**

- If viewing a thread: Thread stays in right panel
- If on `PriorityOnlyRoute` (showing `PriorityPage`): `PriorityOnlyPage` detects `middlePanelVisible` becoming true and automatically navigates to `NewThreadRoute`, moving the priority content to the middle panel and showing `NewThreadPage` in the right panel
- Tabs become invisible but router stays on (or switches to) Activity tab 2
- Left and/or middle panels become visible based on `LayoutBloc` state

**Multi → Single:**

- Current content from right panel becomes active
- Tabs become visible
- User is on Activity tab (tab 2)

**Panel Toggling (Multi-Panel Mode):**

- If middle panel is hidden while on `NewThreadRoute`: Nothing changes, `NewThreadPage` remains in right panel
- If middle panel is shown while on `PriorityOnlyRoute`: `PriorityOnlyPage` detects the change and automatically navigates to `NewThreadRoute`
- If middle panel is hidden while on `PriorityOnlyRoute`: `PriorityOnlyPage` shows `PriorityPage` in the right panel
- Panels preserve their state when hidden/shown
- Content doesn't reload when panels are toggled
- State is maintained in respective Blocs

## Priority Highlighting

**Purpose:** Highlight the currently selected priority in the priorities sidebar (left panel)

**Data Flow:**

1. **NowBloc** stores the current priority as `nowState.priority`
2. **PrioritiesShell** extracts the `priorityId` from `NowBloc` to construct the `PriorityRoute`
3. **PrioritiesShell** passes routes to `AutoTabsRouter`:
   - `PrioritiesRoute()` (Tab 0)
   - `EmptyShellRoute("AgendaShell")()` (Tab 1)
   - `EmptyShellRoute("ActivityShell")()` (Tab 2 — hosts `PriorityRoute(priorityIdString: priorityId)`)
   - `EmptyShellRoute("SearchShell")()` (Tab 3)
   - `EmptyShellRoute("MoreShell")()` (Tab 4)
4. **PriorityWrapper** creates a `PriorityBloc` for the current priority
5. **PrioritiesPage** watches `NowBloc` to determine which priority to highlight
6. **PrioritiesList** uses the current priority from `NowBloc` to highlight the selected item

**Implementation in PriorityWrapper:**

```dart
class PriorityWrapper implements AutoRouteWrapper {
  @override
  Widget wrappedRoute(BuildContext context) {
    return PriorityBlocProvider(
      priorityId: priorityId,
      child: ResizablePanelLayout(
        left: PrioritiesPage(),
        middle: PriorityPage(priorityId: priorityId),
        child: AutoRouter(
          key: routerKey,
          placeholder: (context) => const LoadingPage(),
        ),
      ),
    );
  }
}
```

**Panel Structure:**

- **Left panel:** `PrioritiesPage` shows all priorities
- **Middle panel:** `PriorityPage` shows threads for the current priority
- **Right panel:** `AutoRouter` manages child routes (`NewThreadPage`/`ThreadPage`)

**State synchronization:**

- `NowBloc` is the single source of truth for current priority
- `PriorityBloc` manages the threads for the current priority
- When priority changes, the router navigates to a new `PriorityRoute` with the updated `priorityId`

## Layout Behavior

The layout system adapts based on `LayoutState.middlePanelVisible`:

**Single-Panel Mode:**

- The `AutoRouter` in the right panel displays `PriorityOnlyRoute` by default (showing `PriorityPage`)
- When the user taps a thread, navigation occurs to `ThreadRoute` (showing `ThreadPage`)
- Back navigation returns to `PriorityOnlyRoute` (or triggers `returnFromPriorityToSourceTab` for the priority-level back button)

**Multi-Panel Mode:**

- Left and middle panels become visible alongside the right panel
- The `AutoRouter` continues to manage routing in the right panel
- **Initial state:** `PriorityOnlyRoute` is active, but `PriorityOnlyPage` detects `middlePanelVisible=true` and automatically navigates to `NewThreadRoute`, resulting in:
  - Middle panel: `PriorityPage` (from `ResizablePanelLayout`)
  - Right panel: `NewThreadPage` (from `NewThreadRoute`)
- When the user clicks a thread, the right panel navigates to `ThreadRoute`
- If the middle panel is toggled off while on `NewThreadRoute`, nothing changes (the route remains)
- If the user manually navigates back to `PriorityOnlyRoute` while middle panel is hidden, `PriorityPage` appears in the right panel

## Navigation Actions

### ChangeCurrentActivity

**Purpose:** Navigate to a specific thread or back to the default view

**Location:** `lib/action/activity.dart`

**Behavior:**

```dart
if (thread == null) {
  // Navigate to PriorityRoute base (initial route is PriorityOnlyRoute)
  // In single-panel mode: Shows PriorityPage
  // In multi-panel mode: PriorityOnlyPage auto-navigates to NewThreadRoute
  return ActionRoute(PriorityRoute(...));
} else {
  // Navigate to ThreadRoute
  return ActionRoute(
    PriorityRoute(
      children: [ThreadRoute(threadId: ...)],
    ),
  );
}
```

**Note:** Returns `ActionRoute` which the action system converts to actual navigation

### NewThread

**Purpose:** Navigate to new thread creation

**Handled by:** `_openNewThread` in `PrioritiesShell` (see "Tab navigation — key rules" above)

## Common Pitfalls & Solutions

### Problem: Back button doesn't work in single-panel mode

**Cause:** ResizablePanelLayout not rebuilding when routes change

**Solution:**

- Use `RouteAware` mixin in `_ResizablePanelLayoutState`
- Call `setState()` in `didPush()`, `didPop()`, etc.

### Problem: State lost when switching between single/multi-panel

**Cause:** AutoTabsRouter not always present or routes changing

**Solution:**

- Keep AutoTabsRouter always active in PrioritiesShell
- Never conditionally create/destroy the router
- Use same route instances when toggling panels

### Problem: Flickering when changing priorities

**Cause:** Route navigation causes complete widget teardown and recreation

**Solution:**

- See "Known Issues" section for detailed analysis
- Consider updating state instead of navigating to new route
- Add keys to preserve widget state during rebuilds
- Optimize `PriorityBloc.setPriority()` to avoid full reload

## Panel Visibility State

**Managed by:** `LayoutBloc`

**State properties:**

```dart
class LayoutState {
  final bool multiPanel;        // Is multi-panel mode active?
  final bool leftPanelVisible;  // Is left panel shown? (multi-panel only)
  final bool middlePanelVisible; // Is middle panel shown? (multi-panel only)
  final bool multiPanelPossible; // Is window wide enough for multi-panel?
}
```

**Panel toggle actions:**

- `ToggleLeftSidebarAction` - Shows/hides left panel
- `ToggleMiddleSidebarAction` - Shows/hides middle panel

**Storage:** Panel widths and ratios are persisted in SharedPreferences

## PriorityOnlyPage: Layout-Aware Routing

**Purpose:** `PriorityOnlyPage` is a layout-aware wrapper that prevents duplicate content by adapting to panel visibility.

**Location:** `lib/page/priority.dart`

**Problem it solves:**

- Without it, `PriorityPage` would appear in both the middle panel AND the right panel when in multi-panel mode
- It ensures the right panel always shows unique content (either `PriorityPage` OR `NewThreadPage`, never duplicating what's in the middle)

**Implementation:**

```dart
class PriorityOnlyPage extends StatefulWidget implements AutoRouteWrapper {
  // StatefulWidget to track navigation state
}

class _PriorityOnlyPageState extends State<PriorityOnlyPage> {
  bool _hasNavigated = false; // Prevents navigation loops

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<LayoutBloc, LayoutState>(
      listener: (context, layoutState) {
        // Navigate when middle panel becomes visible
        if (layoutState.middlePanelVisible && !_hasNavigated) {
          _hasNavigated = true;
          context.router.navigate(NewThreadRoute());
        }
      },
      builder: (context, layoutState) {
        if (layoutState.middlePanelVisible) {
          return const LoadingPage(); // Show during navigation
        }
        return PriorityPage(priorityId: widget.priorityId);
      },
    );
  }
}
```

**Behavior:**

- **Listener:** Detects when `middlePanelVisible` becomes true and automatically navigates to `NewThreadRoute`
- **Builder:** Shows different content based on layout state:
  - `middlePanelVisible == false`: Shows `PriorityPage` (single-panel mode or middle panel hidden)
  - `middlePanelVisible == true`: Shows `LoadingPage` during navigation transition
- **State flag:** `_hasNavigated` prevents repeated navigation in the same widget instance

**Key characteristics:**

- Used as the **initial route** under `PriorityRoute` (at path `''`)
- Reacts to layout changes in real-time (not just initial navigation)
- Ensures seamless transitions between single and multi-panel modes
- Prevents content duplication by navigating away when the middle panel appears

## Testing Checklist

When making changes to layout/routing, verify:

**Single-Panel Mode:**

- [ ] Bottom nav shows Focus, New, Search, and More slots (plus Agenda when a calendar is connected)
- [ ] Tapping Focus lands on the priorities list
- [ ] Tapping a priority opens the thread feed; a `←` back button returns to the focus list
- [ ] Tapping New opens the compose flow; the bottom bar remains visible
- [ ] Back arrow in the new-thread compose step returns to step 1 (or exits /new)
- [ ] Tapping Search opens the search page
- [ ] Opening a search result pushes a thread inside the Search tab; Back returns to results
- [ ] Tapping More opens the settings page
- [ ] Tapping the active tab pops its stack to root
- [ ] Switching tabs preserves each tab's scroll / content state
- [ ] Bottom bar is hidden while viewing a thread; visible on /new
- [ ] Current priority is highlighted in the Focus tab's list

**Multi-Panel Mode:**

- [ ] No bottom nav visible
- [ ] Right panel always has content (NewThreadPage or ThreadPage)
- [ ] Clicking threads updates right panel to ThreadPage
- [ ] Clicking different threads switches right panel content
- [ ] Left/middle panels can be toggled independently
- [ ] Toggling panels preserves their state
- [ ] Current priority is highlighted in left panel (priorities sidebar)

**Priority Navigation:**

- [ ] Clicking a priority in sidebar changes the current priority
- [ ] Middle panel updates to show new priority's threads
- [ ] Highlighting updates to show newly selected priority
- [ ] **Known Issue:** Some flickering occurs during priority change (see below)

**Transitions:**

- [ ] Single → Multi while viewing thread: Thread stays visible in right panel
- [ ] Single → Multi while on PriorityOnlyRoute: PriorityOnlyPage detects middlePanelVisible=true and automatically navigates to NewThreadRoute
- [ ] Multi → Single: Last viewed content appears
- [ ] No flashing/blank screens during transitions

**PriorityOnlyPage Behavior:**

- [ ] In single-panel mode: Shows PriorityPage content
- [ ] In multi-panel mode with middle panel visible: Auto-navigates to NewThreadRoute
- [ ] When toggling middle panel on: PriorityOnlyPage navigates to NewThreadRoute
- [ ] When toggling middle panel off while on NewThreadRoute: No change (stays on NewThreadRoute)
- [ ] No duplicate content between middle and right panels

## File Locations

**Core files:**

- `lib/router.dart` - Route definitions (`NewThreadRoute`, `ThreadRoute`, `PriorityRoute`, `SearchRoute`, `MoreRoute`, etc.)
- `lib/widget/priorities_shell.dart` - `AutoTabsRouter`, `NavSlot` enum, tab management (`_handleNavTap`, `_switchOrPopToRoot`, `_openNewThread`, `_isFullScreenRoute`, `_currentNavIndex`, `BottomNavInset`)
- `lib/page/priority.dart` - `PriorityWrapper` (AutoRouteWrapper that sets up ResizablePanelLayout), `returnFromPriorityToSourceTab`
- `lib/page/priorities.dart` - `PrioritiesPage` (list of all priorities)
- `lib/widget/resizable_panel_layout.dart` - Three-panel layout with conditional visibility
- `lib/state/layout.dart` - `LayoutBloc` (manages panel visibility and multi-panel state)
- `lib/state/priority.dart` - `PriorityBloc` (manages threads for a specific priority)
- `lib/state/now.dart` - `NowBloc` (single source of truth for current priority)
- `lib/action/activity.dart` - Thread navigation actions (`ChangeCurrentActivity`, etc.)
- `lib/action/priority.dart` - Priority actions (`ChangeCurrentPriority`, etc.)
- `lib/action/navigation.dart` - Panel toggle actions (`ToggleLeftSidebar`, `ToggleMiddleSidebar`)

## Making Changes Safely

### Adding a new panel

1. Add visibility state to `LayoutState`
2. Add toggle action in `navigation.dart`
3. Update `ResizablePanelLayout` to render the new panel
4. Update panel width calculations
5. Update `buildWhen` conditions to rebuild on visibility changes

### Adding a new route

1. Define route in `router.dart`
2. Add to appropriate children array under `PriorityRoute` (or the relevant shell)
3. Run `flutter pub run build_runner build`
4. Test navigation in both single and multi-panel modes

### Changing navigation behavior

1. Identify if change affects single-panel, multi-panel, or both
2. Update logic in appropriate location:
   - Tab switching: `PrioritiesShell` (`_handleNavTap`, `_switchOrPopToRoot`, `_openNewThread`)
   - Panel visibility: `ResizablePanelLayout` and `LayoutBloc`
   - Routing: `router.dart` route definitions
   - User actions: `lib/action/*.dart`
3. **Keep it simple:** Prefer built-in AutoRoute features over custom logic
4. Add logging with `print()` for debugging
5. Test all navigation paths
6. Remove debug logging before committing

## Architecture Principles

1. **Simplicity:** Keep routing and layout logic as simple as possible
2. **State Preservation:** Keep routers and Blocs alive during layout changes; each tab has its own independent navigator stack
3. **Single Source of Truth:** LayoutBloc owns panel visibility state; NowBloc owns current priority
4. **Separation of Concerns:** ResizablePanelLayout handles panel visibility; AutoRouter handles navigation
5. **Layout-Aware Routing:** Use `BlocConsumer<LayoutBloc, LayoutState>` in route pages to adapt behavior based on layout state (see `PriorityOnlyPage`)
6. **Prevent Content Duplication:** Routes should check layout state to avoid showing the same content in multiple panels
7. **Responsive First:** All features must work in both single and multi-panel modes

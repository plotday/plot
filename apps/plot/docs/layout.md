# Layout and Routing Architecture

This document describes the layout and routing system for the Plot Flutter app, including expected behaviors, implementation details, and guidance for making changes.

## Overview

The app uses a responsive layout system that adapts between **single-panel** (mobile/narrow) and **multi-panel** (desktop/wide) modes. The layout is managed by `LayoutBloc` and routing is handled by AutoRoute.

## Layout Modes

### Single-Panel Mode (Mobile/Narrow Windows)

**Triggers:** Window width < threshold for multi-panel support

**Behavior:**

- Bottom navigation bar with 2 tab routers:
  - **Tab 0 (Priorities):** Shows `PrioritiesPage` - list of all priorities
  - **Tab 1 (Activities):** Shows activity content (PriorityPage or ActivityPage)
  - Tab 2 (More): Opens the menu modal (no real routing)
- **Default tab:** Activities (index 1)
- Activities tab shows:
  - `PriorityPage` by default (via `PriorityOnlyRoute` initial route)
  - `ActivityPage` when an activity is selected (full-screen)
- Back navigation pops from ActivityPage → PriorityPage

**Widget Tree (Single-Panel):**

```
AutoTabsRouter (in PrioritiesShell)
├─ Tab 0: PrioritiesRoute → PrioritiesPage
└─ Tab 1: EmptyShellRoute → PriorityRoute
           └─ PriorityWrapper
              └─ ResizablePanelLayout
                 └─ Right panel: AutoRouter renders:
                    - PriorityOnlyRoute → PriorityOnlyPage → PriorityPage (initial route at '')
                    - NewActivityRoute → NewActivityPage (at /new)
                    - ActivityRoute → ActivityPage (at /:activityId)
```

### Multi-Panel Mode (Desktop/Wide Windows)

**Triggers:** Window width ≥ threshold for multi-panel support

**Behavior:**

- No bottom navigation (tabs not visible)
- Up to 3 panels side-by-side:
  - **Left panel:** `PrioritiesPage` (toggleable, preserves state)
  - **Middle panel:** `PriorityPage` (toggleable, preserves state)
  - **Right panel:** `NewActivityPage` or `ActivityPage` (always visible)
- Right panel **always** has content in multi-panel mode
- When no activity is selected:
  - If middle panel is visible, `PriorityOnlyPage` detects this and automatically navigates to `NewActivityRoute`, showing `NewActivityPage` in the right panel
  - If middle panel is not visible, `PriorityOnlyPage` shows `PriorityPage` in the right panel
- Panels can be toggled independently without affecting content
- Panel visibility is tracked in `LayoutBloc` state

**Widget Tree (Multi-Panel):**

```
AutoTabsRouter (in PrioritiesShell) - no visible tabs
└─ EmptyShellRoute → PriorityRoute
   └─ PriorityWrapper
      └─ ResizablePanelLayout
         ├─ Left: PrioritiesPage (if leftPanelVisible)
         ├─ Middle: PriorityPage (if middlePanelVisible)
         └─ Right: AutoRouter → Shows:
            ├─ PriorityOnlyRoute → PriorityOnlyPage (initial route)
            │  └─ If middlePanelVisible: LoadingPage + navigates to NewActivityRoute
            │  └─ If !middlePanelVisible: PriorityPage
            ├─ NewActivityRoute → NewActivityPage (after auto-navigation or manual)
            └─ ActivityRoute → ActivityPage (when activity selected)
```

## Route Hierarchy

```
AppShellRoute
└─ PrioritiesShellRoute (with AutoTabsRouter)
   ├─ PrioritiesRoute (Tab 0, at /priorities)
   │  └─ PrioritiesPage
   │
   └─ EmptyShellRoute("PriorityShell") (Tab 1, wrapper)
      └─ PriorityRoute (at /:priorityId)
         └─ PriorityWrapper
            └─ ResizablePanelLayout
               ├─ Left panel: PrioritiesPage
               ├─ Middle panel: PriorityPage
               └─ Right panel (AutoRouter):
                  ├─ PriorityOnlyRoute (initial route, at '') → PriorityOnlyPage
                  │  └─ Layout-aware: shows PriorityPage or navigates to NewActivityRoute
                  ├─ NewActivityRoute (at 'new') → NewActivityPage
                  └─ ActivityRoute (at ':activityId') → ActivityPage
```

**Key Points:**

- `PriorityRoute` wraps an `AutoRouter` that manages child routes in the right panel
- `PriorityOnlyRoute` is the initial/default route under `PriorityRoute`
- `PriorityOnlyPage` is **layout-aware**: it uses `BlocConsumer<LayoutBloc, LayoutState>` to:
  - Show `PriorityPage` when `middlePanelVisible` is false (single-panel mode or middle panel hidden)
  - Navigate to `NewActivityRoute` when `middlePanelVisible` is true (multi-panel mode with middle panel shown)
- `ResizablePanelLayout` always renders all three panel widgets (left, middle, right)
- Panel visibility is controlled by `LayoutBloc` state
- In single-panel mode, only the right panel (AutoRouter content) is shown
- In multi-panel mode, left and/or middle panels become visible alongside the right panel

## State Preservation

### AutoTabsRouter Always Active

**Critical:** `AutoTabsRouter` is **always** present in `PrioritiesShell`, even in multi-panel mode where tabs aren't visible.

**Why?** This ensures state is preserved when transitioning between single and multi-panel modes.

**Route Configuration:**

```dart
AutoTabsRouter(
  routes: [
    PrioritiesRoute(),           // Tab 0
    PriorityRoute(...),          // Tab 1
  ],
)
```

**In multi-panel mode:**

- Tab index is fixed at 1 (Activities tab)
- Tab navigation is disabled
- All panels are rendered simultaneously

**In single-panel mode:**

- User can switch between tabs 0 and 1
- Active tab determines which content is shown

### Layout State Transitions

**Single → Multi:**

- If viewing an activity: Activity stays in right panel
- If on `PriorityOnlyRoute` (showing `PriorityPage`): `PriorityOnlyPage` detects `middlePanelVisible` becoming true and automatically navigates to `NewActivityRoute`, moving the priority content to the middle panel and showing `NewActivityPage` in the right panel
- Tabs become invisible but router stays on tab 1
- Left and/or middle panels become visible based on `LayoutBloc` state

**Multi → Single:**

- Current content from right panel becomes active
- Tabs become visible
- User is on Activities tab (tab 1)

**Panel Toggling (Multi-Panel Mode):**

- If middle panel is hidden while on `NewActivityRoute`: Nothing changes, `NewActivityPage` remains in right panel
- If middle panel is shown while on `PriorityOnlyRoute`: `PriorityOnlyPage` detects the change and automatically navigates to `NewActivityRoute`
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
   - `PrioritiesRoute()` (Tab 0 - for single-panel mode)
   - `EmptyShellRoute` wrapping `PriorityRoute(priorityIdString: priorityId)` (Tab 1)
4. **PriorityWrapper** creates a `PriorityBloc` for the current priority
5. **PrioritiesPage** watches `NowBloc` to determine which priority to highlight
6. **PrioritiesList** uses the current priority from `NowBloc` to highlight the selected item

**Implementation in PrioritiesShell:**

```dart
return AutoTabsRouter(
  routes: [
    PrioritiesRoute(),
    EmptyShellRoute("PriorityShell")(),
  ],
```

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
- **Middle panel:** `PriorityPage` shows activities for the current priority
- **Right panel:** `AutoRouter` manages child routes (NewActivityPage/ActivityPage)

**State synchronization:**

- `NowBloc` is the single source of truth for current priority
- `PriorityBloc` manages the activities for the current priority
- When priority changes, the router navigates to a new `PriorityRoute` with the updated `priorityId`

## Layout Behavior

The layout system adapts based on `LayoutState.middlePanelVisible`:

**Single-Panel Mode:**

- The `AutoRouter` in the right panel displays `PriorityOnlyRoute` by default (showing `PriorityPage`)
- When the user taps an activity, navigation occurs to `ActivityRoute` (showing `ActivityPage`)
- Back navigation returns to `PriorityOnlyRoute`

**Multi-Panel Mode:**

- Left and middle panels become visible alongside the right panel
- The `AutoRouter` continues to manage routing in the right panel
- **Initial state:** `PriorityOnlyRoute` is active, but `PriorityOnlyPage` detects `middlePanelVisible=true` and automatically navigates to `NewActivityRoute`, resulting in:
  - Middle panel: `PriorityPage` (from `ResizablePanelLayout`)
  - Right panel: `NewActivityPage` (from `NewActivityRoute`)
- When the user clicks an activity, the right panel navigates to `ActivityRoute`
- If the middle panel is toggled off while on `NewActivityRoute`, nothing changes (the route remains)
- If the user manually navigates back to `PriorityOnlyRoute` while middle panel is hidden, `PriorityPage` appears in the right panel

## Navigation Actions

### ChangeCurrentActivity

**Purpose:** Navigate to a specific activity or back to the default view

**Location:** `lib/action/activity.dart`

**Behavior:**

```dart
if (activity == null) {
  // Navigate to PriorityRoute base (initial route is PriorityOnlyRoute)
  // In single-panel mode: Shows PriorityPage
  // In multi-panel mode: PriorityOnlyPage auto-navigates to NewActivityRoute
  return ActionRoute(PriorityRoute(...));
} else {
  // Navigate to ActivityRoute
  return ActionRoute(
    PriorityRoute(
      children: [ActivityRoute(activityIdString: ...)],
    ),
  );
}
```

**Note:** Returns `ActionRoute` which the action system converts to actual navigation

### NewActivity

**Purpose:** Navigate to new activity creation

**Returns:** `PriorityRoute` with `NewActivityRoute` as a child

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
- It ensures the right panel always shows unique content (either `PriorityPage` OR `NewActivityPage`, never duplicating what's in the middle)

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
          context.router.navigate(NewActivityRoute());
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

- **Listener:** Detects when `middlePanelVisible` becomes true and automatically navigates to `NewActivityRoute`
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

- [ ] Bottom nav shows Priorities and Activities tabs
- [ ] Activities tab is default on first load
- [ ] Clicking an activity navigates to full-screen ActivityPage
- [ ] Back button returns to PriorityPage
- [ ] Switching tabs preserves state
- [ ] Current priority is highlighted in Priorities tab

**Multi-Panel Mode:**

- [ ] No bottom nav visible
- [ ] Right panel always has content (NewActivityPage or ActivityPage)
- [ ] Clicking activities updates right panel to ActivityPage
- [ ] Clicking different activities switches right panel content
- [ ] Left/middle panels can be toggled independently
- [ ] Toggling panels preserves their state
- [ ] Current priority is highlighted in left panel (priorities sidebar)

**Priority Navigation:**

- [ ] Clicking a priority in sidebar changes the current priority
- [ ] Middle panel updates to show new priority's activities
- [ ] Highlighting updates to show newly selected priority
- [ ] **Known Issue:** Some flickering occurs during priority change (see below)

**Transitions:**

- [ ] Single → Multi while viewing activity: Activity stays visible in right panel
- [ ] Single → Multi while on PriorityOnlyRoute: PriorityOnlyPage detects middlePanelVisible=true and automatically navigates to NewActivityRoute
- [ ] Multi → Single: Last viewed content appears
- [ ] No flashing/blank screens during transitions

**PriorityOnlyPage Behavior:**

- [ ] In single-panel mode: Shows PriorityPage content
- [ ] In multi-panel mode with middle panel visible: Auto-navigates to NewActivityRoute
- [ ] When toggling middle panel on: PriorityOnlyPage navigates to NewActivityRoute
- [ ] When toggling middle panel off while on NewActivityRoute: No change (stays on NewActivityRoute)
- [ ] No duplicate content between middle and right panels

## File Locations

**Core files:**

- `lib/router.dart` - Route definitions (NewActivityRoute, ActivityRoute, etc.)
- `lib/widget/priorities_shell.dart` - AutoTabsRouter and tab management
- `lib/page/priority.dart` - PriorityWrapper (AutoRouteWrapper that sets up ResizablePanelLayout)
- `lib/page/priorities.dart` - PrioritiesPage (list of all priorities)
- `lib/widget/resizable_panel_layout.dart` - Three-panel layout with conditional visibility
- `lib/state/layout.dart` - LayoutBloc (manages panel visibility and multi-panel state)
- `lib/state/priority.dart` - PriorityBloc (manages activities for a specific priority)
- `lib/state/now.dart` - NowBloc (single source of truth for current priority)
- `lib/action/activity.dart` - Activity navigation actions (ChangeCurrentActivity, NewActivity, etc.)
- `lib/action/priority.dart` - Priority actions (ChangeCurrentPriority, etc.)
- `lib/action/navigation.dart` - Panel toggle actions (ToggleLeftSidebar, ToggleMiddleSidebar)

## Making Changes Safely

### Adding a new panel

1. Add visibility state to `LayoutState`
2. Add toggle action in `navigation.dart`
3. Update `ResizablePanelLayout` to render the new panel
4. Update panel width calculations
5. Update `buildWhen` conditions to rebuild on visibility changes

### Adding a new route

1. Define route in `router.dart`
2. Add to appropriate children array under `PriorityRoute`
3. Run `flutter pub run build_runner build --delete-conflicting-outputs`
4. Test navigation in both single and multi-panel modes

### Changing navigation behavior

1. Identify if change affects single-panel, multi-panel, or both
2. Update logic in appropriate location:
   - Tab switching: `PrioritiesShell`
   - Panel visibility: `ResizablePanelLayout` and `LayoutBloc`
   - Routing: `router.dart` route definitions
   - User actions: `lib/action/*.dart`
3. **Keep it simple:** Prefer built-in AutoRoute features over custom logic
4. Add logging with `print()` for debugging
5. Test all navigation paths
6. Remove debug logging before committing

## Architecture Principles

1. **Simplicity:** Keep routing and layout logic as simple as possible
2. **State Preservation:** Keep routers and Blocs alive during layout changes
3. **Single Source of Truth:** LayoutBloc owns panel visibility state; NowBloc owns current priority
4. **Separation of Concerns:** ResizablePanelLayout handles panel visibility; AutoRouter handles navigation
5. **Layout-Aware Routing:** Use `BlocConsumer<LayoutBloc, LayoutState>` in route pages to adapt behavior based on layout state (see `PriorityOnlyPage`)
6. **Prevent Content Duplication:** Routes should check layout state to avoid showing the same content in multiple panels
7. **Responsive First:** All features must work in both single and multi-panel modes

## Debugging Tips

### Enable verbose logging

Add temporary `print()` statements to track state and routing:

**Layout state changes:**

```dart
// In ResizablePanelLayout or any BlocBuilder<LayoutBloc>
print('Layout: multiPanel=${layoutState.multiPanel}');
print('Left panel: ${layoutState.leftPanelVisible}');
print('Middle panel: ${layoutState.middlePanelVisible}');
```

**Current route:**

```dart
// Check active route in AutoRouter
final router = context.router;
print('Current route: ${router.current.name}');
print('Stack: ${router.stack.map((r) => r.name).join(' > ')}');
```

### Monitor layout state changes

```dart
// LayoutBloc already logs state transitions:
// LayoutBloc: Change { currentState: ..., nextState: ... }
```

### Check panel visibility

```dart
final layoutState = context.read<LayoutBloc>().state;
print('Multi-panel: ${layoutState.multiPanel}');
print('Left panel: ${layoutState.leftPanelVisible}');
print('Middle panel: ${layoutState.middlePanelVisible}');
```

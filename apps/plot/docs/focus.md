# Focus-Based Highlighting System

## Overview

The Plot app uses a focus-based highlighting system for keyboard navigation of list items. This document describes the intended behavior and implementation details.

## Goals

1. **Single global highlight**: Maintain one (or none) highlighted list item across the entire app
2. **Flutter focus system**: Use Flutter's built-in FocusNode system rather than custom tracking
3. **Keyboard navigation**: Up/Down arrows move focus between items
4. **Context-aware shortcuts**: Different shortcuts available on different pages based on layout
5. **Separate from selection**: Highlight (focus) is independent of selection (the current priority and activity, maintained in state)
6. **Hover compatibility**: Mouse hover clears the keyboard highlight and shows highlight without stealing focus from text fields

## User-Facing Behavior

### ActivityPage (Thread View)

**Shortcuts:**

- **Up**: Move focus to previous item in thread
- **Down**: Move focus to next item in thread
- **Enter**: Open actions menu for focused item
- **Esc**: Clear focus item and focus ActivityEditor

**Behavior:**

- Items include activities and date headers
- Visual highlight shown on focused item
- Enter opens menu with actions specific to that activity
- After menu closes, focus returns to the same item
- When pressing Up/Down without a highlighted item, first press shows highlight without moving; subsequent presses move focus

### PriorityPage (Agenda View)

**Shortcuts (always):**

- **Cmd-Up**: Move focus to previous item in agenda
- **Cmd-Down**: Move focus to next item in agenda
- **Enter**: Open actions menu for focused item
- **Esc**: Clear focus

**Additional shortcuts (when ActivityPage is not visible):**

- **Up**: Same as Cmd-Up
- **Down**: Same as Cmd-Down

**Behavior:**

- Items include activities, priority headers, and date headers
- When ActivityPage is also visible: Up/Down work on ActivityPage, Cmd-Up/Cmd-Down work on PriorityPage
- When ActivityPage is not visible: Both Up/Down and Cmd-Up/Cmd-Down work on PriorityPage
- Focus moves between pages (focusing on PriorityPage clears ActivityPage focus and vice versa)
- Each page remembers its last focused item

### ActionScope Behavior

**Important**: ActionScope is **NOT** affected by focus/highlight changes. It remains based on:

- The currently selected activity (the one open in detail view with blue border)
- The current priority context
- NOT the focused/highlighted item

This means Cmd-K shows actions for the context, not the focused item. Use Enter to get actions for the focused item.

### Hover Behavior

- **Mouse hover**: Shows visual highlight (same style as focus)
- **Does not request focus**: Prevents stealing focus from text fields
- **Clears keyboard focus**: Acts like pressing Esc, then shows hover highlight
- **Separate from focus**: Hover highlight and focus highlight use the same visual but different triggers

## Architecture

### Core Components

#### 1. FocusNode Management

**Location**: `lib/widget/infinite_list.dart` - `InfiniteListController`

**Responsibilities:**

- Creates and manages a `Map<int, FocusNode>` for list items
- Provides `getFocusNode(int index)` to get or create a FocusNode for an item
- Tracks `lastFocusedIndex` for restoration
- Provides `focusedIndex` getter to find currently focused item

**Key Methods:**

```dart
FocusNode getFocusNode(int index)  // Get or create FocusNode for index
void moveFocus(int offset)         // Move focus by offset (+1 down, -1 up)
void requestFocus(int index)       // Focus specific index
void clearFocus()                  // Unfocus all items
int? get focusedIndex              // Currently focused index
int? get lastFocusedIndex          // Last focused index (for restoration)
```

**FocusNode Lifecycle:**

- Created lazily when first accessed via `getFocusNode()`
- Disposed when controller is disposed
- Each FocusNode has a listener that updates `lastFocusedIndex` when it gains focus

#### 2. ListTile Widget

**Location**: `lib/widget/list_tile.dart`

**Changes:**

- Accepts optional `FocusNode? focusNode` parameter
- If provided, wraps content in `Focus` widget with that node
- If not provided, creates internal FocusNode (for backward compatibility)
- Shows highlight when `focusNode.hasFocus || _isHovered`
- Removed dependence on `highlighted` boolean prop (deprecated)

**Highlight Logic:**

```dart
color: _focusNode.hasFocus || (!widget.disableInternalHover && _isHovered)
    ? context.colour.highlight
    : null
```

#### 3. InfiniteList

**Location**: `lib/widget/infinite_list.dart`

**Changes:**

- ItemBuilder signature changed from `(BuildContext, int, bool)` to `(BuildContext, int, FocusNode)`
- Calls `controller.getFocusNode(index)` for each item
- Passes FocusNode to builder function
- Removed static `shortcuts` map (shortcuts now registered at page level)

**Builder Signature:**

```dart
typedef ItemBuilder = Widget? Function(BuildContext context, int index, FocusNode focusNode);
```

#### 4. List Item Widgets

**Widgets Updated:**

- `ActivityWidget` - Accepts `FocusNode? focusNode`, passes to ListTile
- `ActivityDetailWidget` - Accepts `FocusNode? focusNode`, passes to ListTile
- `DayHeader` - Accepts `FocusNode? focusNode`, passes to ListTile
- `AgendaHeader` - Accepts `FocusNode? focusNode`, passes to ListTile

All widgets propagate the FocusNode down to their ListTile.

### Focus Navigation Actions

**Location**: `lib/action/activity.dart`

**Intent Classes:**

```dart
class MoveFocusUpIntent extends Intent
class MoveFocusDownIntent extends Intent
class OpenFocusedItemActionsIntent extends Intent
class ClearItemFocusIntent extends Intent
```

These are used with Flutter's Actions/Shortcuts system to handle keyboard input.

**OpenFocusedItemActions Class:**

- Extends `ShowActions`
- Takes `InfiniteListController` and action builder function
- When run:
  1. Gets `focusedIndex` from controller
  2. Builds action groups for that index
  3. Shows ActionBar dialog
  4. Restores focus to the same item after dialog closes

### Page-Level Integration

#### ActivityPage

**Location**: `lib/page/activity.dart`

**Structure:**

```dart
InfiniteListSelector(
  builder: (context, listController) => Shortcuts(
    shortcuts: {
      Up: MoveFocusUpIntent(),
      Down: MoveFocusDownIntent(),
      Enter: OpenFocusedItemActionsIntent(),
      Esc: ClearItemFocusIntent(),
    },
    child: Actions(
      actions: {
        MoveFocusUpIntent: CallbackAction(...),
        MoveFocusDownIntent: CallbackAction(...),
        OpenFocusedItemActionsIntent: CallbackAction(...),
        ClearItemFocusIntent: CallbackAction(...),
      },
      child: ActionScope(
        // Context-based actions (NOT focus-based)
        child: SelectionActionScope(
          // Selection-based actions (NOT focus-based)
          child: Scaffold(...)
        )
      )
    )
  )
)
```

**Action Handlers:**

- `MoveFocusUpIntent`: Calls `listController.moveFocus(-1)`
- `MoveFocusDownIntent`: Calls `listController.moveFocus(1)`
- `OpenFocusedItemActionsIntent`: Runs `OpenFocusedItemActions` with current state
- `ClearItemFocusIntent`: Calls `listController.clearFocus()`

#### PriorityPage

**Location**: `lib/page/priority.dart`

**Structure:**

```dart
BlocBuilder<LayoutBloc, LayoutState>(
  builder: (context, layoutState) {
    // Build shortcuts conditionally
    final shortcuts = {
      Cmd-Up: MoveFocusUpIntent(),
      Cmd-Down: MoveFocusDownIntent(),
      Enter: OpenFocusedItemActionsIntent(),
      Esc: ClearItemFocusIntent(),
    };

    // When middle panel hidden, add Up/Down too
    if (!layoutState.middlePanelVisible) {
      shortcuts[Up] = MoveFocusUpIntent();
      shortcuts[Down] = MoveFocusDownIntent();
    }

    return InfiniteListSelector(
      builder: (context, listController) => Shortcuts(
        shortcuts: shortcuts,
        child: Actions(
          // Same actions as ActivityPage
          child: SelectionActionScope(...)
        )
      )
    )
  }
)
```

**Conditional Shortcuts:**

- Wraps InfiniteListSelector in `BlocBuilder<LayoutBloc>`
- Checks `layoutState.middlePanelVisible`
- Dynamically builds shortcuts map based on visibility
- This allows Up/Down to work on PriorityPage when ActivityPage is not visible

### ActionBar Integration

**Location**: `lib/widget/action_bar.dart`

**Changes:**

- ItemBuilder receives FocusNode instead of bool
- Uses Flutter's `Actions` widget (imported as `Actions`)
- Handles Enter key via `ActivateListSelectionIntent`
- Checks `listController.focusedIndex ?? listController.lastFocusedIndex`

**Note**: Uses prefixed import to avoid naming conflicts:

```dart
import 'package:flutter/widgets.dart'  show Actions, CallbackAction, KeyEventResult;
```

## State Management

### Focus State

- **Stored in**: FocusNode (Flutter's built-in system)
- **Per-list**: Each `InfiniteListController` manages its own FocusNodes
- **Global**: Only one FocusNode can have focus at a time (Flutter's FocusManager ensures this)
- **Persistence**: `lastFocusedIndex` stored per controller for restoration

### Hover State

- **Stored in**: `InfiniteListController._hoveredIndex`
- **Updated by**: MouseRegion in InfiniteList
- **Behavior**: Hovering calls `setHovered()` which clears focus and updates `_hoveredIndex`

### Selection State

- **Stored in**: Bloc state (`state.activity` for PriorityBloc, `state.activity.id` for ActivityBloc)
- **Displayed as**: Blue left border on selected activity
- **Independent**: Not affected by focus changes

## Edge Cases and Special Behaviors

### Focus and Menu Interaction

1. **Enter pressed on focused item**:

   - Store reference to `focusedNode`
   - Open ActionBar with item's actions
   - After ActionBar closes, call `focusedNode.requestFocus()`

2. **Menu opened via other means** (e.g., Cmd-K):
   - Focus is naturally cleared (ActionBar steals focus)
   - No restoration (because it wasn't triggered by focused item)

### Focus and Text Fields

1. **Text field focused**:

   - List items automatically lose focus (Flutter's FocusManager handles this)
   - No special handling needed

2. **Esc pressed with focused list item**:
   - Clear item focus via `listController.clearFocus()`
   - TODO: Then focus ActivityEditor if present

### Focus and Hover

1. **Mouse hovers over item**:

   - Calls `controller.setHovered(index)`
   - This unfocuses any focused items
   - Shows hover highlight (same visual as focus highlight)
   - Prevents focus stealing from text fields

2. **Mouse leaves item**:

   - Calls `controller.setHovered(null)`
   - Hover highlight removed

3. **Arrow key pressed while hovering**:
   - `moveFocus()` clears `_hoveredIndex`
   - Requests focus on target item
   - Hover highlight replaced by focus highlight

### Panel Visibility Changes

1. **Middle panel closes** (ActivityPage hidden):

   - PriorityPage shortcuts automatically include Up/Down
   - Happens reactively via BlocBuilder

2. **Middle panel opens** (ActivityPage shown):

   - PriorityPage shortcuts revert to Cmd-Up/Cmd-Down only
   - Up/Down now work on ActivityPage

3. **Focus persists**:
   - Each page remembers its `lastFocusedIndex`
   - Focus is not automatically restored (user must press arrow key)

## Implementation Notes

### Import Conflicts

Both Flutter and Plot define `Action` and `Actions` classes. To resolve:

**In pages** (activity.dart, priority.dart):

```dart
import 'package:flutter/widgets.dart'  show Actions, CallbackAction;
```

**In action_bar.dart**:

```dart
import 'package:flutter/widgets.dart' hide Action, Actions;
import 'package:flutter/widgets.dart'  show Actions, CallbackAction, KeyEventResult;
```

### Reverse Lists

ActivityPage uses `reverse: true` on InfiniteList. When calling `moveFocus(offset)`:

- Positive offset moves toward the end (down in visual order)
- Negative offset moves toward the start (up in visual order)
- The offset is NOT reversed by ActivityPage (handled by natural order)

### Index Calculations

- `InfiniteList` items are indexed from `first` to `first + count - 1`
- Controllers track index in this range
- `getFocusNode(index)` uses the list index directly
- Pages map between list index and their internal models (e.g., activity groups)

## Testing Scenarios

### Basic Navigation

- [ ] Up/Down arrows move focus on ActivityPage
- [ ] Cmd-Up/Cmd-Down move focus on PriorityPage
- [ ] First arrow key press shows highlight without moving
- [ ] Subsequent arrow keys move focus normally
- [ ] Focus wraps at boundaries (stays at first/last item)

### Cross-Page Behavior

- [ ] Focusing item on ActivityPage clears PriorityPage focus
- [ ] Focusing item on PriorityPage clears ActivityPage focus
- [ ] Each page remembers last focused item
- [ ] Returning to a page doesn't auto-restore focus (user must press arrow)

### Panel Visibility

- [ ] With middle panel visible: Up/Down work only on ActivityPage
- [ ] With middle panel visible: Cmd-Up/Cmd-Down work only on PriorityPage
- [ ] With middle panel hidden: Up/Down work on PriorityPage
- [ ] With middle panel hidden: Cmd-Up/Cmd-Down work on PriorityPage
- [ ] Shortcuts update reactively when panel visibility changes

### Enter Key

- [ ] Enter with focused item opens menu for that item only
- [ ] Menu shows correct actions for focused item
- [ ] After closing menu, focus returns to same item
- [ ] Enter with no focused item does nothing

### Esc Key

- [ ] Esc with focused item clears focus
- [ ] Esc with focused item focuses ActivityEditor (TODO)
- [ ] Esc with no focused item does nothing (or ActivityEditor if present)
- [ ] Esc in text field still works normally (doesn't clear list focus)

### Hover Interaction

- [ ] Hovering item shows highlight
- [ ] Hovering item doesn't steal focus from text field
- [ ] Hovering item clears any keyboard focus
- [ ] Pressing arrow key while hovering moves focus (replaces hover)
- [ ] Mouse leaving item clears hover highlight

### ActionScope Independence

- [ ] Cmd-K shows actions for context (not focused item)
- [ ] ActionScope doesn't change when focus changes
- [ ] ActionScope updates when selection changes (blue border)
- [ ] Enter key shows actions for focused item (different from Cmd-K)

### Edge Cases

- [ ] Empty lists don't crash
- [ ] Focus survives list updates (items added/removed)
- [ ] Focus cleared when focused item is removed
- [ ] Rapid arrow key presses handled correctly
- [ ] Focus works correctly with date headers and priority headers
- [ ] Focus restoration works after dialog closes

## Known bugs

- [x] On ActivityPage, the focused list item isn't displaying as highlighted
- [x] On ActivityPage, the direction is reversed (need to press down to move up the list)
- [x] On ActivityPage, the root activity is showing as selected. There should be no selected item on ActivityPage.
- [x] When the highlight is not shown (e.g. focus is in ActivityEditor), pressing Up highlights the second item rather than the first. The first Up when the highlight isn't showing should make it visible without moving it.
- [x] When moving between different activity threads, the focus does not reset to the ActivityEditor
- [x] **Esc + ActivityEditor Focus**: When Esc clears item focus, it should focus the ActivityEditor if present. Currently marked with TODO comments in code.

## Known TODOs

- [ ] Implement ActionBar special case: The highlight is set even while focus remains in the search field. The first item in the list (updated as the list changes based on the search) is highlighted by default. Pressing Enter selects the highlighted item. Esc closes the modal (or goes back to the previous one if nested). Up and Down move the highlight. All of this was working before the recent focus changes. ActionBar does not need to use FocusNode -- whatever implementation is best to implement the logic in this case.
- [ ] **Test File Updates**: Test files in `test/widget/bidirectional_list_test.dart` need to be updated to use new API:

  - `initialSelected` renamed to `initialFocusedIndex`
  - `highlighted` property removed (use `focusedIndex`)
  - `move()` method removed (use `moveFocus()`)

- [ ] **Focus Restoration Details**: Verify focus restoration works correctly in all dialog scenarios (ActionBar, other dialogs, etc.)

## File Reference

### Core Files

- `lib/widget/infinite_list.dart` - Focus management controller
- `lib/widget/list_tile.dart` - FocusNode acceptance and visual feedback
- `lib/action/activity.dart` - Intent classes and OpenFocusedItemActions

### Pages

- `lib/page/activity.dart` - ActivityPage shortcuts and handlers
- `lib/page/priority.dart` - PriorityPage conditional shortcuts

### Widgets

- `lib/widget/activity.dart` - ActivityWidget, ActivityDetailWidget
- `lib/widget/event.dart` - DayHeader, AgendaHeader
- `lib/widget/action_bar.dart` - ActionBar focus integration

### State

- `lib/state/layout.dart` - LayoutBloc for panel visibility
- `lib/state/priority.dart` - PriorityBloc for selection state
- `lib/state/activity.dart` - ActivityBloc for selection state

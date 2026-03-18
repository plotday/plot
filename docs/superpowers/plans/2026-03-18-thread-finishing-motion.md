# Thread Finishing Motion Design — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add exit animations (slide-off on mobile, fade on desktop) and height-collapse transitions when finishing threads in the agenda.

**Architecture:** Two reusable animation primitives (`Swipeable.exitOnActivation` and `AnimatedRemoval`) coordinated by `priority.dart`. Mobile swipe triggers slide-off via `Swipeable`, then `AnimatedRemoval` collapses the gap. Desktop click triggers `AnimatedRemoval` fade + collapse. The `FinishThread` command's `optimisticallyRemoveThread` call moves from the command into the animation completion callback.

**Tech Stack:** Flutter animations (`AnimationController`, `Tween`, `CurvedAnimation`), `ClipRect` for height collapse, `Opacity` for fade.

**Spec:** `docs/superpowers/specs/2026-03-18-thread-finishing-motion-design.md`

---

## File Structure

| File | Responsibility | Action |
|------|---------------|--------|
| `apps/plot/lib/widget/animated_removal.dart` | Reusable height-collapse + fade widget | Create |
| `apps/plot/lib/widget/widget.dart` | Barrel export file | Modify (add export) |
| `apps/plot/lib/widget/swipeable.dart` | Swipe gesture handler | Modify (add exit mode) |
| `apps/plot/lib/widget/thread.dart` | Thread list item widget | Modify (add `onSwipeExit` param) |
| `apps/plot/lib/page/priority.dart` | Agenda list builder, coordination point | Modify (wrap threads, wire callbacks) |
| `apps/plot/lib/command/thread.dart` | `FinishThread` command | Modify (remove direct optimistic removal, add animation trigger for desktop) |

---

### Task 1: Create `AnimatedRemoval` Widget

**Files:**
- Create: `apps/plot/lib/widget/animated_removal.dart`
- Modify: `apps/plot/lib/widget/widget.dart` (add export)

This widget wraps a child and can animate it out of the layout via height collapse (optionally preceded by a fade).

- [ ] **Step 1: Create `animated_removal.dart`**

```dart
import 'package:plot/widget/widget.dart';

/// Wraps a child widget and can animate its removal from the layout.
///
/// Call [AnimatedRemovalState.remove] to trigger the exit animation:
/// - Height collapses from full to zero (both platforms)
/// - Optional fade-out before collapse (desktop icon-click path)
///
/// The [onRemoved] callback fires after all animations complete.
class AnimatedRemoval extends StatefulWidget {
  final Widget child;
  final VoidCallback? onRemoved;

  const AnimatedRemoval({
    required this.child,
    this.onRemoved,
    super.key,
  });

  @override
  State<AnimatedRemoval> createState() => AnimatedRemovalState();
}

class AnimatedRemovalState extends State<AnimatedRemoval>
    with TickerProviderStateMixin {
  static const _collapseDuration = Duration(milliseconds: 150);
  static const _collapseDelay = Duration(milliseconds: 80);
  static const _fadeDuration = Duration(milliseconds: 120);
  static const _fadeDelay = Duration(milliseconds: 50);

  late final AnimationController _collapseController;
  late final AnimationController _fadeController;
  late final Animation<double> _collapseAnimation;
  late final Animation<double> _fadeAnimation;

  bool _removing = false;

  @override
  void initState() {
    super.initState();
    _collapseController = AnimationController(
      duration: _collapseDuration,
      vsync: this,
    );
    _fadeController = AnimationController(
      duration: _fadeDuration,
      vsync: this,
    );
    _collapseAnimation = CurvedAnimation(
      parent: _collapseController,
      curve: Curves.easeOut,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _collapseController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  /// Trigger the removal animation.
  ///
  /// When [fade] is true (desktop path), fades the child out before
  /// collapsing. When false (mobile path), only collapses height
  /// (the slide-off is handled by [Swipeable]).
  Future<void> remove({bool fade = false}) async {
    if (_removing) return;
    _removing = true;

    if (fade) {
      // Start fade after delay
      await Future.delayed(_fadeDelay);
      if (!mounted) return;
      _fadeController.forward();
    }

    // Start collapse after delay (from the beginning of remove())
    // For fade path: collapse starts at +80ms, fade started at +50ms
    // For non-fade path: collapse starts at +80ms from call
    final elapsed = fade ? _fadeDelay : Duration.zero;
    final remaining = _collapseDelay - elapsed;
    if (remaining > Duration.zero) {
      await Future.delayed(remaining);
    }
    if (!mounted) return;

    await _collapseController.forward();
    widget.onRemoved?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!_removing) return widget.child;

    Widget child = widget.child;

    // Apply fade if active
    if (_fadeController.isAnimating || _fadeController.isCompleted) {
      child = FadeTransition(
        opacity: ReverseAnimation(_fadeAnimation),
        child: child,
      );
    }

    // Apply height collapse
    return SizeTransition(
      sizeFactor: ReverseAnimation(_collapseAnimation),
      axisAlignment: -1.0,
      child: child,
    );
  }
}
```

- [ ] **Step 2: Add export to `widget.dart`**

In `apps/plot/lib/widget/widget.dart`, add this line alongside the other exports:

```dart
export 'animated_removal.dart';
```

- [ ] **Step 3: Run analysis**

Run: `cd apps/plot && flutter analyze lib/widget/animated_removal.dart`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/animated_removal.dart apps/plot/lib/widget/widget.dart
git commit -m "feat: add AnimatedRemoval widget for height collapse + fade"
```

---

### Task 2: Add `exitOnActivation` to `Swipeable`

**Files:**
- Modify: `apps/plot/lib/widget/swipeable.dart`

Add a callback that, when set, makes the swipe slide off-screen instead of sliding back when released in an active zone.

- [ ] **Step 1: Add `exitOnActivation` field to `Swipeable`**

In `apps/plot/lib/widget/swipeable.dart`, add the field to the `Swipeable` class (line 19, after `endLongCommand`):

```dart
  /// When set, on release in an active zone the child slides off-screen
  /// instead of sliding back to origin. The callback receives the resolved
  /// command. The caller is responsible for executing the command.
  final Future<void> Function(Command command)? exitOnActivation;
```

Add it to the constructor (line 26, before `super.key`):

```dart
    this.exitOnActivation,
```

- [ ] **Step 2: Change `SingleTickerProviderStateMixin` to `TickerProviderStateMixin`**

On line 35, change:
```dart
class _SwipeableState extends State<Swipeable>
    with SingleTickerProviderStateMixin {
```
to:
```dart
class _SwipeableState extends State<Swipeable>
    with TickerProviderStateMixin {
```

This is needed because we'll add a second `AnimationController` for the slide-off animation.

- [ ] **Step 3: Add slide-off animation controller in `initState`**

Add a new controller after `_slideBackController` (around line 46):

```dart
  late AnimationController _slideOffController;
  late Animation<double> _slideOffAnimation;
```

In `initState`, after the existing `_slideBackAnimation` setup (after line 62):

```dart
    _slideOffController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _slideOffAnimation =
        Tween<double>(begin: 0, end: 0).animate(
          CurvedAnimation(parent: _slideOffController, curve: Curves.easeIn),
        )..addListener(() {
          setState(() {
            _dragOffset = _slideOffAnimation.value;
          });
        });
```

In `dispose`, add before `_slideBackController.dispose()`:

```dart
    _slideOffController.dispose();
```

- [ ] **Step 4: Modify `_onHorizontalDragEnd` to support exit mode**

Replace the body of `_onHorizontalDragEnd` (lines 161-187) with:

```dart
  void _onHorizontalDragEnd(DragEndDetails details) async {
    if (!_isDragging) return;

    final isRight = _dragOffset > 0;
    final command = _activeCommand(right: isRight, zone: _zone);

    // Exit mode: slide off-screen instead of sliding back
    if (_zone != _SwipeZone.idle &&
        command != null &&
        widget.exitOnActivation != null) {
      final screenWidth = MediaQuery.sizeOf(context).width;
      final target = isRight ? screenWidth : -screenWidth;

      _slideOffAnimation = Tween<double>(
        begin: _dragOffset,
        end: target,
      ).animate(
        CurvedAnimation(parent: _slideOffController, curve: Curves.easeIn),
      );

      _slideOffController.reset();
      await _slideOffController.forward();

      if (mounted) {
        await widget.exitOnActivation!(command);
      }

      // Reset state (widget may be disposed by now via removal)
      if (mounted) {
        setState(() {
          _dragOffset = 0;
          _startDragX = 0;
          _zone = _SwipeZone.idle;
          _isDragging = false;
        });
      }
      return;
    }

    // Default: animate slide back to original position
    _slideBackAnimation = Tween<double>(begin: _dragOffset, end: 0).animate(
      CurvedAnimation(parent: _slideBackController, curve: Curves.easeOut),
    );

    _slideBackController.reset();
    await _slideBackController.forward();

    // Execute command if in an active zone
    if (_zone != _SwipeZone.idle && command != null && mounted) {
      await context.run(command);
    }

    // Reset state
    setState(() {
      _dragOffset = 0;
      _startDragX = 0;
      _zone = _SwipeZone.idle;
      _isDragging = false;
    });
  }
```

- [ ] **Step 5: Run analysis**

Run: `cd apps/plot && flutter analyze lib/widget/swipeable.dart`
Expected: No errors.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/widget/swipeable.dart
git commit -m "feat: add exitOnActivation to Swipeable for slide-off exit"
```

---

### Task 3: Add `onSwipeExit` to `ThreadWidget`

**Files:**
- Modify: `apps/plot/lib/widget/thread.dart:20-52` (class definition), `784-813` (Swipeable construction)

Pass the exit callback through to `Swipeable`.

- [ ] **Step 1: Add `onSwipeExit` parameter to `ThreadWidget`**

In `apps/plot/lib/widget/thread.dart`, add to the `ThreadWidget` class fields (after line 48, before the `@override`):

```dart
  final Future<void> Function(Command command)? onSwipeExit;
```

Add to the constructor (after `this.reorderableIndex,` on line 34):

```dart
    this.onSwipeExit,
```

- [ ] **Step 2: Wire `exitOnActivation` to `Swipeable` instances**

There are two `Swipeable` constructions in `build()`. Add `exitOnActivation: widget.onSwipeExit,` to both.

At line 785 (reorderable path):
```dart
          ? Swipeable(
              key: ValueKey(activity.id),
              startCommand: swipeRightShort,
              startLongCommand: swipeRightLong,
              endCommand: swipeLeftShort,
              endLongCommand: swipeLeftLong,
              exitOnActivation: widget.onSwipeExit,
              child: listTile,
            )
```

At line 805 (non-reorderable path):
```dart
      return Swipeable(
        key: ValueKey(activity.id),
        startCommand: swipeRightShort,
        startLongCommand: swipeRightLong,
        endCommand: swipeLeftShort,
        endLongCommand: swipeLeftLong,
        exitOnActivation: widget.onSwipeExit,
        child: listTile,
      );
```

- [ ] **Step 3: Run analysis**

Run: `cd apps/plot && flutter analyze lib/widget/thread.dart`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/thread.dart
git commit -m "feat: add onSwipeExit param to ThreadWidget"
```

---

### Task 4: Wire Up Animations in `priority.dart`

**Files:**
- Modify: `apps/plot/lib/page/priority.dart:1178-1203` (agenda thread builder)

Wrap each agenda thread in `AnimatedRemoval` and connect the swipe-exit callback.

- [ ] **Step 1: Wrap `ThreadWidget` in `AnimatedRemoval`**

In `apps/plot/lib/page/priority.dart`, find the `activity:` callback in the `_buildList` builder (around line 1178). Replace the existing return:

```dart
              activity: (agendaActivity) {
                final isBeingDragged = controller.draggingIndex == index;
                return [
                  ThreadWidget(
                    key: ValueKey(
                      'activitywidget_${agendaActivity.thread.id}${agendaActivity.thread.occurrence != null ? '_${agendaActivity.thread.occurrence}' : ''}${agendaActivity.thread.isLinkScheduleInstance ? '_link' : ''}',
                    ),
                    activity: agendaActivity.thread,
                    selected:
                        !isBeingDragged &&
                        state.thread != null &&
                        agendaActivity.thread.id == state.thread!.id,
                    now: agendaActivity.now,
                    isNext: agendaActivity.isNext,
                    focusNode: focusNode,
                    context: state.context,
                    showSubPriority: true,
                    showEventTiming: true,
                    reorderableIndex:
                        enableReorder &&
                            !agendaActivity.thread.isLinkScheduleInstance
                        ? reorderableIndex
                        : null,
                  ),
                ];
              },
```

With:

```dart
              activity: (agendaActivity) {
                final isBeingDragged = controller.draggingIndex == index;
                final removalKey = GlobalKey<AnimatedRemovalState>(
                  debugLabel: 'removal_${agendaActivity.thread.id}',
                );
                return [
                  AnimatedRemoval(
                    key: removalKey,
                    onRemoved: () {
                      context.read<PriorityBloc>().optimisticallyRemoveThread(
                        agendaActivity.thread.id,
                      );
                    },
                    child: ThreadWidget(
                      key: ValueKey(
                        'activitywidget_${agendaActivity.thread.id}${agendaActivity.thread.occurrence != null ? '_${agendaActivity.thread.occurrence}' : ''}${agendaActivity.thread.isLinkScheduleInstance ? '_link' : ''}',
                      ),
                      activity: agendaActivity.thread,
                      selected:
                          !isBeingDragged &&
                          state.thread != null &&
                          agendaActivity.thread.id == state.thread!.id,
                      now: agendaActivity.now,
                      isNext: agendaActivity.isNext,
                      focusNode: focusNode,
                      context: state.context,
                      showSubPriority: true,
                      showEventTiming: true,
                      onSwipeExit: (command) async {
                        // Swipeable already slid the thread off-screen.
                        // Now collapse the gap, then execute the command.
                        await removalKey.currentState?.remove();
                        if (context.mounted) {
                          await context.run(command);
                        }
                      },
                      reorderableIndex:
                          enableReorder &&
                              !agendaActivity.thread.isLinkScheduleInstance
                          ? reorderableIndex
                          : null,
                    ),
                  ),
                ];
              },
```

- [ ] **Step 2: Run analysis**

Run: `cd apps/plot && flutter analyze lib/page/priority.dart`
Expected: No errors (or only pre-existing warnings).

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "feat: wrap agenda threads in AnimatedRemoval, wire swipe exit"
```

---

### Task 5: Update `FinishThread` and Wire Desktop Animation

**Files:**
- Modify: `apps/plot/lib/command/thread.dart:709-751` (`FinishThread` class)
- Modify: `apps/plot/lib/widget/thread.dart:20-52` (add `onDesktopFinish`), `253-260` (icon button), `857-860`, `954-957` (count tag FinishThread), `131` (swipe left long)
- Modify: `apps/plot/lib/page/priority.dart` (pass `onDesktopFinish` to ThreadWidget)

The desktop click path needs to trigger fade + collapse animation before the command logic runs. The approach: add an `onBeforeRun` callback to `FinishThread` that fires before any logic. The mobile swipe path handles animation separately via `onSwipeExit` (Task 4), so `FinishThread` receives `onBeforeRun` to skip its own `optimisticallyRemoveThread` call on swipe too.

- [ ] **Step 1: Add `onBeforeRun` to `FinishThread`**

In `apps/plot/lib/command/thread.dart`, add a field to `FinishThread` (after `final bool bump;` on line 727):

```dart
  /// Optional callback invoked before the finish logic runs.
  /// When set, the caller is responsible for optimistic removal (e.g. via
  /// animation). When null, FinishThread calls optimisticallyRemoveThread
  /// directly as a fallback (keyboard shortcuts, command palette, etc.).
  final Future<void> Function(BuildContext context)? onBeforeRun;
```

Add `this.onBeforeRun` to the constructor (after `this.bump = true,` on line 714):

```dart
    this.onBeforeRun,
```

- [ ] **Step 2: Modify `FinishThread.run()` to use callback**

Replace `FinishThread.run()` (lines 729-751) with:

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (onBeforeRun != null) {
      // Animation layer handles optimistic removal
      await onBeforeRun!(context);
    } else {
      // No animation: immediate optimistic removal (keyboard, command palette)
      context.read<PriorityBloc?>()?.optimisticallyRemoveThread(thread.id);
    }
    HapticFeedback.mediumImpact();
    await onUpdate(thread.copyWith(todo: false, bump: bump));

    // Complete notes assigned to current user
    final actorId = Base.actorId;
    final notes = await Note.getForThread(thread.id);
    for (final note in notes) {
      if (note.hasTag(Tag.todo, actorId)) {
        await note.completeFor(actorId).save();
      }
    }

    // Set done status on links assigned to user or unassigned
    if (context.mounted) {
      await _setLinkDoneStatusForUser(context, thread.id, actorId);
    }

    return const CommandDone();
  }
```

- [ ] **Step 3: Add `onDesktopFinish` parameter to `ThreadWidget`**

In `apps/plot/lib/widget/thread.dart`, add the field (after `onSwipeExit` added in Task 3):

```dart
  /// Called before a finish command runs on desktop (icon click path).
  /// Should trigger the fade+collapse removal animation.
  final Future<void> Function()? onDesktopFinish;
```

Add `this.onDesktopFinish,` to the constructor.

- [ ] **Step 4: Wire `onBeforeRun` into all `FinishThread` constructions in `thread.dart`**

There are 4 places where `FinishThread` is constructed in `thread.dart`. All need `onBeforeRun` wired when `onDesktopFinish` is available:

**Line 131** (swipe left long command — mobile only, does NOT need `onBeforeRun`):
```dart
    return FinishThread(activity, bump: bump);
```
No change needed. This is a swipe command — it goes through the `onSwipeExit` path, not through `FinishThread.run()` directly. When `exitOnActivation` is set on `Swipeable`, the command is passed to the `onSwipeExit` callback which handles animation and then calls `context.run(command)`. The `onBeforeRun` being null means the fallback `optimisticallyRemoveThread` runs — but `AnimatedRemoval.onRemoved` already called it. To prevent the double call, pass a no-op `onBeforeRun`:

```dart
    return FinishThread(activity, bump: bump, onBeforeRun: widget.onSwipeExit != null ? (_) async {} : null);
```

**Line 255** (desktop icon button):
```dart
              FinishThread(activity, bump: bump),
```
Change to:
```dart
              FinishThread(
                activity,
                bump: bump,
                onBeforeRun: widget.onDesktopFinish != null
                    ? (_) => widget.onDesktopFinish!()
                    : null,
              ),
```

**Lines 859 and 956** (count tag FinishThread — appears in both async and sync paths):
```dart
                        ? FinishThread(activity, stateIcon: true, bump: bump)
```
Change both to:
```dart
                        ? FinishThread(
                            activity,
                            stateIcon: true,
                            bump: bump,
                            onBeforeRun: widget.onDesktopFinish != null
                                ? (_) => widget.onDesktopFinish!()
                                : null,
                          )
```

- [ ] **Step 5: Pass `onDesktopFinish` from `priority.dart`**

In `priority.dart`, update the `ThreadWidget` inside the `AnimatedRemoval` wrapper (from Task 4) to include `onDesktopFinish`:

```dart
                    child: ThreadWidget(
                      // ... existing params ...
                      onSwipeExit: (command) async {
                        await removalKey.currentState?.remove();
                        if (context.mounted) {
                          await context.run(command);
                        }
                      },
                      onDesktopFinish: () async {
                        await removalKey.currentState?.remove(fade: true);
                      },
                      // ... remaining params ...
                    ),
```

- [ ] **Step 6: Run analysis**

Run: `cd apps/plot && flutter analyze lib/command/thread.dart lib/widget/thread.dart lib/page/priority.dart`
Expected: No errors.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/command/thread.dart apps/plot/lib/widget/thread.dart apps/plot/lib/page/priority.dart
git commit -m "feat: coordinate desktop finish animation via onBeforeRun callback"
```

---

### Task 6: Manual Testing and Polish

**Files:** None (testing only)

- [ ] **Step 1: Test mobile swipe-right finish**

The app should already be running with hot reload. On a mobile device or simulator:
1. Navigate to a priority with agenda threads
2. Swipe right on a thread past the 80px threshold
3. Verify: thread slides off-screen right (150ms), then the gap collapses (150ms)
4. Verify: haptic feedback fires (lightImpact at threshold, mediumImpact on release)
5. Verify: total animation takes ~230ms

- [ ] **Step 2: Test desktop icon-click finish**

On desktop:
1. Navigate to a priority with agenda threads
2. Click the leading finish icon on a todo thread
3. Verify: icon briefly pulses (if visible), thread fades out, gap collapses
4. Verify: total animation takes ~230ms

Note: The icon pulse (1.0 → 1.15 → 1.0 scale) from the spec is NOT implemented in this plan. The `Button` widget handles the click, and adding a scale animation to it would require modifying `Button`. If the fade + collapse feels complete without the pulse, skip it. If it's needed, add a scale animation to the `AnimatedRemoval` widget's `remove(fade: true)` path — animate the child's scale before fading.

- [ ] **Step 3: Test swipe-right finish with scheduled copy**

1. Find a thread with a link schedule instance (appears twice in agenda)
2. Swipe-finish the todo entry
3. Verify: the todo entry animates out, the scheduled copy stays

- [ ] **Step 4: Test swipe-right on non-finish commands**

1. Swipe right on a thread where the command is NOT FinishThread (if any exist)
2. Verify: existing slide-back behavior still works (no exit animation)
3. Swipe left (archive, etc.) — verify unaffected

- [ ] **Step 5: Test rapid successive finishes**

1. Quickly finish multiple threads in a row
2. Verify: each one animates independently, no visual glitches

- [ ] **Step 6: Run full analysis**

Run: `cd apps/plot && flutter analyze`
Expected: No new errors introduced.

- [ ] **Step 7: Commit any polish fixes**

If adjustments are needed during testing, commit them:

```bash
git add -p
git commit -m "fix: polish thread finishing animations"
```

---

## Notes for the Implementer

1. **The `AnimatedRemoval.onRemoved` callback timing is critical.** It fires `optimisticallyRemoveThread`, which rebuilds the list and removes the item from the data. This must happen AFTER the height collapse is complete, not before — otherwise the widget gets unmounted mid-animation.

2. **`GlobalKey` lifecycle:** The `removalKey` is created inside the builder callback. Each time the list rebuilds, new keys are created. This is fine — the key only needs to survive for the ~230ms of the animation. If the list rebuilds during animation (e.g., from another thread update), the animation may be interrupted. This is acceptable — the optimistic removal will still fire.

3. **Preventing double `optimisticallyRemoveThread` calls.** There are three paths to `FinishThread.run()`:
   - **Mobile swipe:** `onSwipeExit` collapses the gap → `AnimatedRemoval.onRemoved` calls `optimisticallyRemoveThread` → then `context.run(command)` enters `FinishThread.run()`. The swipe path passes a no-op `onBeforeRun: (_) async {}` so `FinishThread.run()` skips its own `optimisticallyRemoveThread`.
   - **Desktop click:** `onBeforeRun` triggers `onDesktopFinish()` which calls `remove(fade: true)` → `AnimatedRemoval.onRemoved` calls `optimisticallyRemoveThread`. No double call.
   - **Keyboard/command palette:** `onBeforeRun` is null → `FinishThread.run()` calls `optimisticallyRemoveThread` directly (no animation, instant removal).

4. **Icon pulse is optional.** The spec mentions a 1.0 → 1.15 → 1.0 scale pulse on the desktop finish icon. This is not included in the plan because it requires modifying `Button` widget internals. The fade + collapse should feel complete without it. Add it later if desired.
